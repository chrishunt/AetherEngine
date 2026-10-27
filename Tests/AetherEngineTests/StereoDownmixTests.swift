import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// `LoadOptions.stereoDownmix`: surround mixed to stereo in the engine with the LFE kept, for a stereo
/// system whose route would otherwise mix it without one (tvOS drops the LFE from both a Dolby stream
/// and multichannel PCM when it mixes to two channels).
@Suite("Stereo downmix keeps the LFE")
struct StereoDownmixTests {

    private static let minus3 = 0.5.squareRoot()
    private static let fivePointOneGain = 1 / (1 + 2 * minus3)

    // MARK: - The mix

    @Test("5.1: fronts at unity, centre and surrounds at -3 dB, all under the A/52 Lo/Ro gain")
    func fivePointOneCoefficients() {
        let c = StereoDownmixer.coefficients(
            for: [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER, AV_CHAN_LOW_FREQUENCY,
                  AV_CHAN_SIDE_LEFT, AV_CHAN_SIDE_RIGHT],
            levels: .standard, lfeGainDB: 4)
        let g = Self.fivePointOneGain
        #expect(approx(c.left, [g, 0, Self.minus3 * g, 0, Self.minus3 * g, 0]))
        #expect(approx(c.right, [0, g, Self.minus3 * g, 0, 0, Self.minus3 * g]))
        #expect(c.isLFE == [false, false, false, true, false, false])
        #expect(abs(c.lfe - pow(10, 4.0 / 20) * g) < 1e-12)
    }

    @Test("7.1: back surrounds count as surround, and the overall gain is the 5.1 one")
    func sevenPointOneCoefficients() {
        let c = StereoDownmixer.coefficients(
            for: [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER, AV_CHAN_LOW_FREQUENCY,
                  AV_CHAN_BACK_LEFT, AV_CHAN_BACK_RIGHT, AV_CHAN_SIDE_LEFT, AV_CHAN_SIDE_RIGHT],
            levels: .standard, lfeGainDB: 4)
        let g = Self.fivePointOneGain
        #expect(approx(c.left, [g, 0, Self.minus3 * g, 0, Self.minus3 * g, 0, Self.minus3 * g, 0]),
                "dialogue lands at the same level whether the title is 5.1 or 7.1")
        #expect(approx(c.right, [0, g, Self.minus3 * g, 0, 0, Self.minus3 * g, 0, Self.minus3 * g]))
    }

    @Test("a layout that names no order reads as the default for its count, so raw PCM keeps its LFE")
    func unspecifiedOrderReadsAsDefault() {
        var layout = AVChannelLayout()
        layout.order = AV_CHANNEL_ORDER_UNSPEC
        layout.nb_channels = 6
        #expect(StereoDownmixer.channels(of: &layout) == [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER,
                                                          AV_CHAN_LOW_FREQUENCY, AV_CHAN_BACK_LEFT, AV_CHAN_BACK_RIGHT])
    }

    @Test("a channel the mix does not know contributes nothing rather than landing somewhere")
    func unknownChannelsAreSilent() {
        let c = StereoDownmixer.coefficients(for: [AV_CHAN_FRONT_LEFT, AV_CHAN_NONE],
                                             levels: .standard, lfeGainDB: 4)
        #expect(c.left[1] == 0 && c.right[1] == 0 && !c.isLFE[1])
    }

    @Test("a Dolby stream's own Lo/Ro levels set the mix and its normalization")
    func streamLevelsAreAdopted() {
        let mixer = StereoDownmixer(channels: [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER,
                                               AV_CHAN_LOW_FREQUENCY, AV_CHAN_SIDE_LEFT, AV_CHAN_SIDE_RIGHT],
                                    sampleRate: 48_000, settings: .cinema)
        // A/52's defaults when a stream sets none: centre -4.5 dB, surround -6 dB.
        let levels = DownmixLevels(center: pow(10, -4.5 / 20), surround: 0.5)
        #expect(mixer.adopt(levels))
        #expect(!mixer.adopt(levels), "the same levels again change nothing")
        let g = 1 / (1 + levels.center + levels.surround)
        #expect(abs(mixer.coefficients.left[0] - g) < 1e-12)
        #expect(abs(mixer.coefficients.left[2] - levels.center * g) < 1e-12)
        #expect(abs(mixer.coefficients.left[4] - levels.surround * g) < 1e-12)
    }

    @Test("the levels are read from a decoded frame's downmix side data")
    func levelsFromFrameSideData() throws {
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        let f = try #require(frame)
        #expect(DownmixLevels(frame: f) == nil, "no side data, no levels")
        let side = try #require(av_frame_new_side_data(f, AV_FRAME_DATA_DOWNMIX_INFO,
                                                       MemoryLayout<AVDownmixInfo>.size))
        var info = AVDownmixInfo()
        info.center_mix_level = 0.5
        info.surround_mix_level = 0.25
        UnsafeMutableRawPointer(side.pointee.data).storeBytes(of: info, as: AVDownmixInfo.self)
        #expect(DownmixLevels(frame: f) == DownmixLevels(center: 0.5, surround: 0.25))
    }

    // MARK: - The LFE

    @Test("bass in the LFE reaches both sides at the LFE gain; above the crossover it does not")
    func lfeIsLowPassedIntoBothSides() {
        let rate = 48_000
        let layout = [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_LOW_FREQUENCY]
        func level(ofLFETone hz: Double) -> (Double, Double) {
            let mixer = StereoDownmixer(channels: layout, sampleRate: Int32(rate), settings: .cinema)
            var input = [Float](repeating: 0, count: rate * 3)
            for n in 0..<rate { input[n * 3 + 2] = Float(0.25 * sin(2 * .pi * hz * Double(n) / Double(rate))) }
            var out = input.withUnsafeBufferPointer { mixer.process($0.baseAddress!, frames: rate) }
            out += mixer.drain()
            // The second half, past the filter's settling.
            let half = stride(from: rate, to: out.count, by: 2)
            let l = rms(half.map { out[$0] }), r = rms(half.map { out[$0 + 1] })
            return (l, r)
        }
        let expected = 0.25 / 2.0.squareRoot() * pow(10, 4.0 / 20) / (1 + 2 * Self.minus3)
            / (1 + pow(40.0 / 120, 4))  // fourth-order Linkwitz-Riley at 40 Hz
        let (l40, r40) = level(ofLFETone: 40)
        #expect(abs(20 * log10(l40 / expected)) < 0.1, "40 Hz: \(l40) against \(expected)")
        #expect(abs(l40 - r40) < 1e-9, "the LFE goes to both sides equally")
        let (l1k, _) = level(ofLFETone: 1000)
        #expect(20 * log10(l1k / expected) < -60, "1 kHz in the LFE is filtered out as bass management does")
    }

    // MARK: - The limiter

    @Test("below the ceiling the mix is exact, with every frame back where it went in")
    func belowCeilingIsUntouchedAndAligned() {
        let layout = [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT]
        let mixer = StereoDownmixer(channels: layout, sampleRate: 48_000, settings: .cinema)
        let frames = 5_000
        var input = [Float](repeating: 0, count: frames * 2)
        for n in 0..<frames {
            input[2 * n] = Float(0.5 * sin(Double(n) * 0.01))
            input[2 * n + 1] = Float(-0.5 * cos(Double(n) * 0.013))
        }
        var out = input.withUnsafeBufferPointer { mixer.process($0.baseAddress!, frames: frames) }
        out += mixer.drain()
        #expect(out.count == input.count, "the latency is compensated: as many frames out as in")
        let g = Float(Self.fivePointOneGain)
        for i in stride(from: 0, to: out.count, by: 997) {
            #expect(out[i] == Float(Double(input[i]) * Double(g)), "frame \(i / 2) sits where it went in, untouched")
        }
        #expect(mixer.stats.framesLimited == 0)
    }

    @Test("a mix past full scale never exceeds -1 dBFS")
    func ceilingHolds() {
        let layout = [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER, AV_CHAN_LOW_FREQUENCY,
                      AV_CHAN_SIDE_LEFT, AV_CHAN_SIDE_RIGHT]
        let mixer = StereoDownmixer(channels: layout, sampleRate: 48_000, settings: .cinema)
        let frames = 48_000
        var input = [Float](repeating: 0, count: frames * 6)
        for n in 0..<frames {
            let bass = Float(sin(2 * .pi * 35 * Double(n) / 48_000))
            let burst: Float = (n / 2_400) % 2 == 0 ? 1 : -1
            for ch in 0..<6 { input[n * 6 + ch] = ch == 3 ? bass : burst }
        }
        var out = input.withUnsafeBufferPointer { mixer.process($0.baseAddress!, frames: frames) }
        out += mixer.drain()
        let peak = out.map { abs(Double($0)) }.max() ?? 0
        #expect(peak <= LookaheadLimiter.ceiling + 1e-6, "peak \(20 * log10(peak)) dBFS")
        #expect(mixer.stats.framesLimited > 0)
        #expect(out.count == input.count / 3)
    }

    @Test("an input shorter than the look-ahead still comes out whole")
    func shortInputDrainsWhole() {
        let mixer = StereoDownmixer(channels: [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT],
                                    sampleRate: 48_000, settings: .cinema)
        let input: [Float] = Array(repeating: 0.1, count: 20)
        var out = input.withUnsafeBufferPointer { mixer.process($0.baseAddress!, frames: 10) }
        #expect(out.isEmpty, "everything is still inside the look-ahead")
        out += mixer.drain()
        #expect(out.count == 20)
    }

    @Test("a reset forgets what was in flight and takes the latency up again")
    func resetStartsOver() {
        let mixer = StereoDownmixer(channels: [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT],
                                    sampleRate: 48_000, settings: .cinema)
        let input: [Float] = Array(repeating: 0.2, count: 2_000)
        _ = input.withUnsafeBufferPointer { mixer.process($0.baseAddress!, frames: 1_000) }
        #expect(mixer.outputLag == mixer.latency)
        mixer.reset()
        #expect(mixer.outputLag == 0)
        let out = input.withUnsafeBufferPointer { mixer.process($0.baseAddress!, frames: 1_000) }
        #expect(out.count == 2 * (1_000 - mixer.latency))
    }

    // MARK: - Where it applies

    @Test("only surround is mixed, and only when the host asks")
    func appliesToSurroundOnly() {
        #expect(HLSVideoEngine.bridgesForStereoDownmix(.cinema, channels: 6))
        #expect(HLSVideoEngine.bridgesForStereoDownmix(.cinema, channels: 3))
        #expect(!HLSVideoEngine.bridgesForStereoDownmix(.cinema, channels: 2))
        #expect(!HLSVideoEngine.bridgesForStereoDownmix(.cinema, channels: 1))
        #expect(!HLSVideoEngine.bridgesForStereoDownmix(nil, channels: 6))
        #expect(LoadOptions().stereoDownmix == nil, "off unless the host asks")
    }

    @Test("a mixed surround source is FLAC in either mode; anything else keeps the mode's encoder")
    func encoderChoice() {
        #expect(AudioBridge.bridgeEncoder(for: .surroundCompat, sourceChannels: 6, stereoDownmix: .cinema) == AV_CODEC_ID_FLAC)
        #expect(AudioBridge.bridgeEncoder(for: .surroundCompat, sourceChannels: 6) == AV_CODEC_ID_EAC3)
        #expect(AudioBridge.bridgeEncoder(for: .surroundCompat, sourceChannels: 2, stereoDownmix: .cinema) == AV_CODEC_ID_FLAC)
    }

    @Test("Dolby decodes at the dialogue reference with no compression; other decoders are left alone")
    func dolbyDecoderOptions() {
        let expected = ["drc_scale": "0", "target_level": "-31"]
        for codec in [AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3] {
            let options = Dictionary(uniqueKeysWithValues: StereoDownmix.decoderOptions(for: codec).map { ($0.key, $0.value) })
            #expect(options == expected)
        }
        #expect(StereoDownmix.decoderOptions(for: AV_CODEC_ID_TRUEHD).isEmpty)
        #expect(StereoDownmix.decoderOptions(for: AV_CODEC_ID_DTS).isEmpty)
    }

    // MARK: - Through the bridge

    @Test("a tone in the LFE alone comes out of the bridge as stereo FLAC with the tone in it")
    func bridgeCarriesTheLFE() throws {
        let wav = makeWAV(channels: 6, seconds: 1) { channel, n in
            channel == 3 ? 9000 * sin(2 * .pi * 40 * Double(n) / 48_000) : 0  // FL FR FC LFE BL BR
        }
        var (packets, codecpar, tb, demuxer) = try readAudioPackets(wav: wav)
        defer { freeAll(&packets); demuxer.close() }

        let bridge = try AudioBridge(srcCodecpar: codecpar, srcTimeBase: tb, mode: .lossless, stereoDownmix: .cinema)
        defer { bridge.close() }
        #expect(bridge.isDownmixing)
        let out = try #require(bridge.encoderCodecpar)
        #expect(out.pointee.codec_id == AV_CODEC_ID_FLAC)
        #expect(out.pointee.ch_layout.nb_channels == 2)
        #expect(out.pointee.bits_per_raw_sample == 24)

        var encoded: [UnsafeMutablePointer<AVPacket>] = []
        defer { freeAll(&encoded) }
        for p in packets { encoded.append(contentsOf: try bridge.feed(packet: p)) }
        encoded.append(contentsOf: bridge.flush())

        let pcm = try decodeFLAC(encoded, codecpar: out)
        #expect(pcm.left.count > 40_000, "the whole second came out, \(pcm.left.count) frames")
        let tail = 24_000..<min(pcm.left.count, 44_000)
        let l = rms(Array(pcm.left[tail])), r = rms(Array(pcm.right[tail]))
        let expected = 9000.0 / 32_768 / 2.0.squareRoot() * pow(10, 4.0 / 20) / (1 + 2 * Self.minus3)
            / (1 + pow(40.0 / 120, 4))
        #expect(abs(20 * log10(l / expected)) < 0.2, "left \(l) against \(expected)")
        #expect(abs(20 * log10(r / expected)) < 0.2, "right \(r) against \(expected)")
    }

    @Test("without the option the same source stays 6 channels, as before")
    func bridgeUnchangedWithoutTheOption() throws {
        let wav = makeWAV(channels: 6, seconds: 0.2) { _, _ in 0 }
        var (packets, codecpar, tb, demuxer) = try readAudioPackets(wav: wav)
        defer { freeAll(&packets); demuxer.close() }
        let bridge = try AudioBridge(srcCodecpar: codecpar, srcTimeBase: tb, mode: .lossless)
        defer { bridge.close() }
        #expect(!bridge.isDownmixing)
        #expect(bridge.encoderCodecpar?.pointee.ch_layout.nb_channels == 6)
    }

    @Test("a stereo source is left alone even with the option on")
    func stereoSourceIsNotMixed() throws {
        let wav = makeWAV(channels: 2, seconds: 0.2) { _, _ in 0 }
        var (packets, codecpar, tb, demuxer) = try readAudioPackets(wav: wav)
        defer { freeAll(&packets); demuxer.close() }
        let bridge = try AudioBridge(srcCodecpar: codecpar, srcTimeBase: tb, mode: .lossless, stereoDownmix: .cinema)
        defer { bridge.close() }
        #expect(!bridge.isDownmixing)
        #expect(bridge.encoderCodecpar?.pointee.bits_per_raw_sample == 16, "a 16-bit stereo source keeps its own path")
    }

    // MARK: - Fixtures

    private func approx(_ a: [Double], _ b: [Double]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-12 }
    }

    private func rms(_ x: [Float]) -> Double {
        x.isEmpty ? 0 : (x.reduce(0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
    }

    private func rms(_ x: [Double]) -> Double {
        x.isEmpty ? 0 : (x.reduce(0) { $0 + $1 * $1 } / Double(x.count)).squareRoot()
    }

    /// 48 kHz 16-bit PCM WAV, each sample from `value(channel, frame)`.
    private func makeWAV(channels: Int, seconds: Double, value: (Int, Int) -> Double) -> Data {
        let frames = Int(48_000 * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for n in 0..<frames {
            for ch in 0..<channels {
                let v = Int16(max(-32_768, min(32_767, value(ch, n).rounded())))
                withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
            }
        }
        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels)); u32(48_000)
        u32(UInt32(48_000 * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        str("data"); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    private func readAudioPackets(
        wav: Data
    ) throws -> (packets: [UnsafeMutablePointer<AVPacket>],
                 codecpar: UnsafeMutablePointer<AVCodecParameters>,
                 timeBase: AVRational,
                 demuxer: Demuxer) {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: wav))
        let audioIdx = demuxer.audioStreamIndex
        guard audioIdx >= 0, let stream = demuxer.stream(at: audioIdx) else {
            throw NSError(domain: "test", code: 1)
        }
        var packets: [UnsafeMutablePointer<AVPacket>] = []
        while let packet = try demuxer.readPacket() {
            if packet.pointee.stream_index == audioIdx {
                packets.append(packet)
            } else {
                var p: UnsafeMutablePointer<AVPacket>? = packet
                trackedPacketFree(&p)
            }
        }
        return (packets, stream.pointee.codecpar, stream.pointee.time_base, demuxer)
    }

    private func freeAll(_ packets: inout [UnsafeMutablePointer<AVPacket>]) {
        for p in packets {
            var pp: UnsafeMutablePointer<AVPacket>? = p
            trackedPacketFree(&pp)
        }
        packets.removeAll()
    }

    /// Decodes the bridge's FLAC back to float stereo.
    private func decodeFLAC(_ packets: [UnsafeMutablePointer<AVPacket>],
                            codecpar: UnsafeMutablePointer<AVCodecParameters>) throws -> (left: [Double], right: [Double]) {
        let codec = try #require(avcodec_find_decoder(AV_CODEC_ID_FLAC))
        var ctx: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&ctx) }
        let dec = try #require(ctx)
        #expect(avcodec_parameters_to_context(dec, codecpar) >= 0)
        #expect(avcodec_open2(dec, codec, nil) >= 0)
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        let f = try #require(frame)
        var left: [Double] = [], right: [Double] = []
        func receive() {
            while avcodec_receive_frame(dec, f) >= 0 {
                let n = Int(f.pointee.nb_samples)
                // FLAC decodes 24-bit as interleaved S32.
                let samples = UnsafeRawPointer(f.pointee.data.0!).assumingMemoryBound(to: Int32.self)
                for i in 0..<n {
                    left.append(Double(samples[2 * i]) / 2_147_483_648)
                    right.append(Double(samples[2 * i + 1]) / 2_147_483_648)
                }
            }
        }
        for p in packets {
            _ = avcodec_send_packet(dec, p)
            receive()
        }
        _ = avcodec_send_packet(dec, nil)
        receive()
        return (left, right)
    }
}
