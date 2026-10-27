import Foundation
import AetherLibavcodec
import AetherLibavutil

/// Mixes every surround track to stereo inside the engine, with the LFE (subwoofer) channel kept.
///
/// For a host whose output is a stereo system with real bass behind a route that takes only two
/// channels, such as an Apple TV feeding a TV whose optical output drives a stereo amplifier and its
/// subwoofers. With the track left as surround, the system mixes it to stereo on the way out, and the
/// standard mix (ITU-R BS.775, A/52's Lo/Ro) has no LFE term: on tvOS both a Dolby stream and the FLAC
/// bridge's multichannel PCM reach the output without the subwoofer channel, which in a modern action
/// mix carries most of the bass. The engine cannot tell such a route from a receiver that takes the
/// surround whole (with Continuous Audio Connection on, tvOS reports 32 channels for every HDMI sink,
/// AE#794), so the host says so.
///
/// Set, every track with more than two channels is decoded and mixed here, including the AAC, AC-3
/// and E-AC-3 that otherwise stream-copy, and reaches the system as 24-bit stereo FLAC. A stereo or
/// mono track is untouched. The mix:
///
/// - Left and right at unity, centre and surrounds at the stream's own Lo/Ro mix levels where a Dolby
///   stream carries them (A/52 §7.8.2), -3 dB otherwise (BS.775). Side and back surrounds both count
///   as surround; heights fold in at -3 dB.
/// - The LFE through a 120 Hz fourth-order low-pass, as bass management filters it, into both sides at
///   `lfeGainDB`.
/// - One overall gain, 1 / (1 + centre + surround), the A/52 normalization of a 5.1 Lo/Ro mix, so
///   dialogue lands where a Dolby decoder's stereo puts it whatever the layout.
/// - Dolby streams decoded at the -31 dB dialogue reference with no dynamic range compression, as a
///   Dolby decoder in line mode with compression off plays them, so a title is as loud as before.
/// - A look-ahead peak limiter at -1 dBFS for the rare moment the LFE pushes the sum past full scale.
///   It leaves every sample below the ceiling untouched, and its latency is compensated, so the audio
///   keeps its timestamps.
///
/// Atmos objects and heights are not kept (an E-AC-3 JOC track is mixed from its 5.1 bed); the option
/// takes precedence over `objectAudioRendering`.
public struct StereoDownmix: Sendable, Hashable {
    /// The LFE's gain into EACH of left and right, in dB, after its low-pass.
    ///
    /// Cinema and home-theatre calibration plays the LFE 10 dB above a main channel. The same bass from
    /// two speakers adds 6 dB where they meet, so +4 dB into each side reproduces that +10 dB:
    /// `cinemaLFEGainDB`, the default. RFC 7845's Opus downmix, which Jellyfin also uses, puts the LFE
    /// at the centre's level, about 7 dB lower; small speakers that cannot reproduce it may want that.
    public var lfeGainDB: Double

    public static let cinemaLFEGainDB = 4.0

    public init(lfeGainDB: Double = StereoDownmix.cinemaLFEGainDB) {
        self.lfeGainDB = lfeGainDB
    }

    /// The cinema calibration, `cinemaLFEGainDB`.
    public static let cinema = StereoDownmix()

    /// Whether a track of `channels` is mixed. Stereo and mono already are what the route plays.
    static func applies(toChannels channels: Int32) -> Bool { channels > 2 }

    /// Decoder options for the source codec: AC-3 and E-AC-3 decode at the -31 dB dialogue reference
    /// with no dynamic range compression (FFmpeg's decoder compresses by default, and applies the
    /// dialogue level only when asked). Other decoders take none.
    static func decoderOptions(for codecID: AVCodecID) -> [(key: String, value: String)] {
        guard codecID == AV_CODEC_ID_AC3 || codecID == AV_CODEC_ID_EAC3 else { return [] }
        return [("drc_scale", "0"), ("target_level", "-31")]
    }
}

/// The stream's own Lo/Ro mix levels, linear. `nil` where it carries none.
struct DownmixLevels: Equatable {
    var center: Double
    var surround: Double

    static let standard = DownmixLevels(center: 0.5.squareRoot(), surround: 0.5.squareRoot())

    /// From a decoded frame's `AV_FRAME_DATA_DOWNMIX_INFO`, which FFmpeg's AC-3 family exports on every
    /// frame (A/52's defaults when the stream sets none). Anything else carries none.
    init?(frame: UnsafePointer<AVFrame>) {
        guard let side = av_frame_get_side_data(frame, AV_FRAME_DATA_DOWNMIX_INFO),
              let data = side.pointee.data,
              Int(side.pointee.size) >= MemoryLayout<AVDownmixInfo>.size
        else { return nil }
        let info = UnsafeRawPointer(data).load(as: AVDownmixInfo.self)
        guard info.center_mix_level.isFinite, info.center_mix_level >= 0,
              info.surround_mix_level.isFinite, info.surround_mix_level >= 0
        else { return nil }
        self.init(center: info.center_mix_level, surround: info.surround_mix_level)
    }

    init(center: Double, surround: Double) {
        self.center = center
        self.surround = surround
    }
}

/// One session's stereo mix: interleaved float in, interleaved float stereo out. Not thread-safe; the
/// bridge and the decoder call it under their own locks.
final class StereoDownmixer {

    /// Each input channel's gain into left and right, and whether it is an LFE (which goes through the
    /// low-pass first and takes the LFE gain instead).
    struct Coefficients: Equatable {
        var left: [Double]
        var right: [Double]
        var isLFE: [Bool]
        /// Linear LFE gain into each side, the overall gain applied.
        var lfe: Double
    }

    let channels: [AVChannel]
    let sampleRate: Int32
    let settings: StereoDownmix
    private(set) var levels: DownmixLevels
    private(set) var coefficients: Coefficients

    private var lowPass: [Biquad]
    private var limiter: LookaheadLimiter
    /// Output frames still to drop after a reset: the limiter's latency, so output frame n is input
    /// frame n and the caller's timestamps hold.
    private var latencyToDrop: Int

    /// Input frames taken since the last reset, capped at the latency. How far the next output's start
    /// lies before the start of the input that produced it.
    var outputLag: Int { limiter.latency - latencyToDrop }

    var latency: Int { limiter.latency }
    var stats: LookaheadLimiter.Stats { limiter.stats }

    init(channels: [AVChannel], sampleRate: Int32, settings: StereoDownmix,
         levels: DownmixLevels = .standard) {
        self.channels = channels
        self.sampleRate = sampleRate
        self.settings = settings
        self.levels = levels
        coefficients = Self.coefficients(for: channels, levels: levels, lfeGainDB: settings.lfeGainDB)
        let rate = Double(max(sampleRate, 1))
        lowPass = [Biquad(lowPassAt: 120, sampleRate: rate), Biquad(lowPassAt: 120, sampleRate: rate)]
        limiter = LookaheadLimiter(sampleRate: rate)
        latencyToDrop = limiter.latency
    }

    /// The labels of `layout`'s channels in order. A layout that names no order (raw PCM in a WAV or a
    /// Matroska file says only how many channels it has) is read as FFmpeg's default for that count,
    /// which is how every other stage of the engine reads it.
    static func channels(of layout: UnsafePointer<AVChannelLayout>) -> [AVChannel] {
        guard layout.pointee.order == AV_CHANNEL_ORDER_UNSPEC else {
            return (0..<layout.pointee.nb_channels).map { av_channel_layout_channel_from_index(layout, UInt32($0)) }
        }
        var named = AVChannelLayout()
        av_channel_layout_default(&named, layout.pointee.nb_channels)
        defer { av_channel_layout_uninit(&named) }
        return (0..<named.nb_channels).map { av_channel_layout_channel_from_index(&named, UInt32($0)) }
    }

    /// The mix for `channels`, overall gain included. Unknown labels contribute nothing.
    static func coefficients(for channels: [AVChannel], levels: DownmixLevels, lfeGainDB: Double) -> Coefficients {
        let c = levels.center, s = levels.surround
        let gain = 1 / (1 + c + s)
        let minus3 = 0.5.squareRoot()
        // Front left/right of centre sit half-way between a front and the centre: equal-power pan.
        let inner = (cos(Double.pi / 8), sin(Double.pi / 8))
        var left: [Double] = [], right: [Double] = [], isLFE: [Bool] = []
        for channel in channels {
            let (l, r, lfe): (Double, Double, Bool)
            switch channel {
            case AV_CHAN_FRONT_LEFT, AV_CHAN_WIDE_LEFT: (l, r, lfe) = (1, 0, false)
            case AV_CHAN_FRONT_RIGHT, AV_CHAN_WIDE_RIGHT: (l, r, lfe) = (0, 1, false)
            case AV_CHAN_FRONT_CENTER: (l, r, lfe) = (c, c, false)
            case AV_CHAN_FRONT_LEFT_OF_CENTER: (l, r, lfe) = (inner.0, inner.1, false)
            case AV_CHAN_FRONT_RIGHT_OF_CENTER: (l, r, lfe) = (inner.1, inner.0, false)
            case AV_CHAN_SIDE_LEFT, AV_CHAN_BACK_LEFT, AV_CHAN_SURROUND_DIRECT_LEFT: (l, r, lfe) = (s, 0, false)
            case AV_CHAN_SIDE_RIGHT, AV_CHAN_BACK_RIGHT, AV_CHAN_SURROUND_DIRECT_RIGHT: (l, r, lfe) = (0, s, false)
            case AV_CHAN_BACK_CENTER: (l, r, lfe) = (s * minus3, s * minus3, false)
            case AV_CHAN_TOP_FRONT_LEFT, AV_CHAN_TOP_SIDE_LEFT, AV_CHAN_TOP_BACK_LEFT: (l, r, lfe) = (minus3, 0, false)
            case AV_CHAN_TOP_FRONT_RIGHT, AV_CHAN_TOP_SIDE_RIGHT, AV_CHAN_TOP_BACK_RIGHT: (l, r, lfe) = (0, minus3, false)
            case AV_CHAN_TOP_CENTER, AV_CHAN_TOP_FRONT_CENTER, AV_CHAN_TOP_BACK_CENTER: (l, r, lfe) = (0.5, 0.5, false)
            case AV_CHAN_LOW_FREQUENCY, AV_CHAN_LOW_FREQUENCY_2: (l, r, lfe) = (0, 0, true)
            default: (l, r, lfe) = (0, 0, false)
            }
            left.append(l * gain)
            right.append(r * gain)
            isLFE.append(lfe)
        }
        return Coefficients(left: left, right: right, isLFE: isLFE,
                            lfe: pow(10, lfeGainDB / 20) * gain)
    }

    /// Adopt the levels a frame carries. True when they changed the mix.
    @discardableResult
    func adopt(_ newLevels: DownmixLevels) -> Bool {
        guard newLevels != levels else { return false }
        levels = newLevels
        coefficients = Self.coefficients(for: channels, levels: newLevels, lfeGainDB: settings.lfeGainDB)
        return true
    }

    /// Mix `frames` interleaved frames of `channels.count` channels. Returns interleaved stereo, fewer
    /// frames than went in only until the limiter's latency has been taken up after a reset.
    func process(_ input: UnsafePointer<Float>, frames: Int) -> [Float] {
        var output: [Float] = []
        output.reserveCapacity(frames * 2)
        let n = channels.count
        let cl = coefficients.left, cr = coefficients.right, isLFE = coefficients.isLFE
        let lfeGain = coefficients.lfe
        for frame in 0..<frames {
            let base = frame * n
            var l = 0.0, r = 0.0, lfe = 0.0
            for ch in 0..<n {
                let x = Double(input[base + ch])
                if isLFE[ch] { lfe += x } else { l += cl[ch] * x; r += cr[ch] * x }
            }
            lfe = lowPass[1].process(lowPass[0].process(lfe)) * lfeGain
            emit(l + lfe, r + lfe, into: &output)
        }
        return output
    }

    /// The tail still inside the limiter at end of stream: its latency in frames of silence pushed
    /// through, so the last input frames come out (and no more than went in, on an input shorter than
    /// the latency).
    func drain() -> [Float] {
        var output: [Float] = []
        for _ in 0..<limiter.latency {
            let lfe = lowPass[1].process(lowPass[0].process(0)) * coefficients.lfe
            emit(lfe, lfe, into: &output)
        }
        reset()
        return output
    }

    /// Forget everything in flight (a seek or a restart).
    func reset() {
        for i in lowPass.indices { lowPass[i].reset() }
        limiter.reset()
        latencyToDrop = limiter.latency
    }

    private func emit(_ l: Double, _ r: Double, into output: inout [Float]) {
        let (ol, or) = limiter.process(l, r)
        if latencyToDrop > 0 { latencyToDrop -= 1; return }
        output.append(Float(ol))
        output.append(Float(or))
    }
}

/// A second-order section, transposed direct form II, in double precision.
struct Biquad {
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var z1 = 0.0, z2 = 0.0

    /// Butterworth low-pass (Q = 1/sqrt 2), from the Audio EQ Cookbook. Two in series make the
    /// fourth-order Linkwitz-Riley that bass management uses.
    init(lowPassAt frequency: Double, sampleRate: Double) {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * 0.5.squareRoot())
        let cosw = cos(w0)
        let a0 = 1 + alpha
        b0 = (1 - cosw) / 2 / a0
        b1 = (1 - cosw) / a0
        b2 = b0
        a1 = -2 * cosw / a0
        a2 = (1 - alpha) / a0
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() { z1 = 0; z2 = 0 }
}

/// Stereo-linked look-ahead peak limiter that guarantees no output sample exceeds `ceiling`.
///
/// Each frame asks for the gain that would bring its louder side to the ceiling (1 when it is already
/// below). The gain applied is the minimum of that over the look-ahead window, released towards 1 with a
/// `release` time constant, then averaged over the window, and the audio is delayed by the window so the
/// gain is fully down when the peak arrives. Every value averaged for the frame leaving the delay line is
/// at most the gain that frame asked for, so the average is too: the ceiling holds exactly. Where nothing
/// asks for less than 1 the gain is exactly 1 and the audio passes bit for bit, only delayed.
struct LookaheadLimiter {
    static let ceiling = pow(10, -1.0 / 20)
    static let lookaheadSeconds = 0.005
    static let releaseSeconds = 0.1

    struct Stats: Equatable {
        /// Frames that left with a gain below 1.
        var framesLimited: Int64 = 0
        /// The lowest gain applied, linear.
        var minimumGain: Double = 1
    }

    /// Frames in the look-ahead window.
    let window: Int
    /// Frames between a frame going in and coming out: the frame leaving is the oldest the window's
    /// gain average has fully seen.
    var latency: Int { window - 1 }
    private let releaseCoefficient: Double

    private var delayLeft: [Double], delayRight: [Double]
    private var delayPosition = 0
    private var gains: [Double]
    private var gainSum = 0.0
    private var gainPosition = 0
    private var released = 1.0
    /// Monotonic deque of (frame, wanted gain) for the window minimum.
    private var minFrames: [Int], minValues: [Double]
    private var minHead = 0, minCount = 0
    private var frame = 0
    private(set) var stats = Stats()

    init(sampleRate: Double) {
        window = max(1, Int((Self.lookaheadSeconds * sampleRate).rounded()))
        releaseCoefficient = 1 - exp(-1 / (Self.releaseSeconds * sampleRate))
        delayLeft = Array(repeating: 0, count: max(window - 1, 1))
        delayRight = delayLeft
        gains = Array(repeating: 1, count: window)
        gainSum = Double(window)
        minFrames = Array(repeating: 0, count: window)
        minValues = Array(repeating: 1, count: window)
    }

    mutating func process(_ l: Double, _ r: Double) -> (Double, Double) {
        let peak = max(abs(l), abs(r))
        let wanted = peak > Self.ceiling ? Self.ceiling / peak : 1

        // Minimum of the wanted gain over the last `window` frames: drop what left the window, then
        // what the new value undercuts, then queue it.
        if minCount > 0, minFrames[minHead] <= frame - window {
            minHead = (minHead + 1) % window
            minCount -= 1
        }
        while minCount > 0, minValues[(minHead + minCount - 1) % window] >= wanted { minCount -= 1 }
        let tail = (minHead + minCount) % window
        minFrames[tail] = frame
        minValues[tail] = wanted
        minCount += 1
        let held = minValues[minHead]
        frame += 1

        // Instant attack, smooth release, never above what the window holds.
        released = min(held, released + (1 - released) * releaseCoefficient)
        if released > 1 - 1e-9 { released = 1 }

        // Average over the window. Back at unity everywhere the running sum is reset to exact, so
        // rounding left over from a limited stretch never touches audio below the ceiling.
        gainSum += released - gains[gainPosition]
        gains[gainPosition] = released
        gainPosition = (gainPosition + 1) % window
        let gain: Double
        if released == 1, gainSum >= Double(window) - 1e-9 {
            gainSum = Double(window)
            gain = 1
        } else {
            gain = min(1, gainSum / Double(window))
        }

        let (outL, outR): (Double, Double)
        if window == 1 {
            (outL, outR) = (l, r)
        } else {
            (outL, outR) = (delayLeft[delayPosition], delayRight[delayPosition])
            delayLeft[delayPosition] = l
            delayRight[delayPosition] = r
            delayPosition = (delayPosition + 1) % (window - 1)
        }
        if gain < 1 {
            stats.framesLimited += 1
            stats.minimumGain = min(stats.minimumGain, gain)
        }
        return (outL * gain, outR * gain)
    }

    mutating func reset() {
        for i in delayLeft.indices { delayLeft[i] = 0; delayRight[i] = 0 }
        for i in gains.indices { gains[i] = 1 }
        gainSum = Double(window)
        delayPosition = 0
        gainPosition = 0
        released = 1
        minHead = 0
        minCount = 0
        frame = 0
    }
}
