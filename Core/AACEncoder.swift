import Foundation
import AVFoundation
import CoreMedia

/// Encode le son de l'app capturé par ReplayKit (`.audioApp`) en AAC-LC et le met en fMP4
/// (piste audio seule). Le navigateur le joue dans un `<audio>` séparé de la vidéo :
/// la timeline vidéo est volontairement « compressée » sur écran statique, alors que l'audio
/// doit rester continu.
///
/// Le format d'entrée ReplayKit varie (souvent Int16 big-endian 44,1 kHz stéréo) : il est lu
/// dans chaque buffer et converti à la main en Float32 natif avant AVAudioConverter.
final class AACEncoder {
    struct InitSegment { let codec: String; let data: Data }

    var onInit: ((InitSegment) -> Void)?
    var onFragment: ((Data) -> Void)?

    private let bitrate: Int
    private var converter: AVAudioConverter?
    private var pcmFormat: AVAudioFormat?
    private var inputKey = ""
    private var sampleRate = 48_000.0
    private var decodeTime: UInt64 = 0
    private var sequence: UInt32 = 0
    private var pendingPackets: [Data] = []
    private let lock = NSLock()

    init(bitrate: Int = 128_000) { self.bitrate = bitrate }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        converter = nil; inputKey = ""; pendingPackets = []
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mChannelsPerFrame > 0, asbd.mSampleRate > 0 else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }

        lock.lock(); defer { lock.unlock() }

        let key = "\(asbd.mSampleRate)-\(asbd.mChannelsPerFrame)-\(asbd.mFormatFlags)-\(asbd.mBitsPerChannel)"
        if key != inputKey || converter == nil {
            guard setup(asbd) else { return }
            inputKey = key
        }
        guard let converter, let pcmFormat,
              let pcm = Self.floatBuffer(from: sampleBuffer, asbd: asbd, frames: frames, format: pcmFormat) else { return }

        var fed = false
        while true {
            let out = AVAudioCompressedBuffer(format: converter.outputFormat, packetCapacity: 8,
                                              maximumPacketSize: converter.maximumOutputPacketSize)
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if fed { inputStatus.pointee = .noDataNow; return nil }
                fed = true
                inputStatus.pointee = .haveData
                return pcm
            }
            if status == .error { NSLog("[TeslaMirror] AAC: \(error?.localizedDescription ?? "?")"); return }
            for i in 0..<Int(out.packetCount) {
                guard let d = out.packetDescriptions?[i] else { continue }
                pendingPackets.append(Data(bytes: out.data.advanced(by: Int(d.mStartOffset)), count: Int(d.mDataByteSize)))
            }
            if out.packetCount == 0 || status != .haveData { break }
        }
        // 4 trames AAC (~85 ms) par fragment : peu de surcoût, latence correcte.
        if pendingPackets.count >= 4 { flushFragment() }
    }

    private func setup(_ asbd: AudioStreamBasicDescription) -> Bool {
        let channels: AVAudioChannelCount = asbd.mChannelsPerFrame >= 2 ? 2 : 1
        sampleRate = asbd.mSampleRate
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                           channels: channels, interleaved: false) else { return false }
        var outDesc = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC,
                                                  mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                                  mBytesPerFrame: 0, mChannelsPerFrame: channels,
                                                  mBitsPerChannel: 0, mReserved: 0)
        guard let outFormat = AVAudioFormat(streamDescription: &outDesc),
              let conv = AVAudioConverter(from: inFormat, to: outFormat) else { return false }
        conv.bitRate = channels == 2 ? bitrate : bitrate / 2
        converter = conv
        pcmFormat = inFormat
        pendingPackets = []
        decodeTime = 0
        let asc = Self.audioSpecificConfig(sampleRate: sampleRate, channels: Int(channels))
        onInit?(InitSegment(codec: "mp4a.40.2",
                            data: Self.initSegment(sampleRate: UInt32(sampleRate), channels: UInt16(channels),
                                                   asc: asc, bitrate: UInt32(conv.bitRate))))
        NSLog("[TeslaMirror] AAC \(sampleRate) Hz, \(channels) canaux (entrée flags=\(asbd.mFormatFlags) bits=\(asbd.mBitsPerChannel))")
        return true
    }

    private func flushFragment() {
        let packets = pendingPackets
        pendingPackets = []
        sequence &+= 1
        onFragment?(Self.fragment(packets: packets, sequence: sequence, baseDecodeTime: decodeTime))
        decodeTime += UInt64(packets.count * 1024)
    }

    // MARK: - PCM → Float32 non entrelacé

    static func floatBuffer(from sampleBuffer: CMSampleBuffer, asbd: AudioStreamBasicDescription,
                            frames: Int, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var raw = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &raw) == noErr,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let dst = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(frames)

        let flags = asbd.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let bigEndian = flags & kAudioFormatFlagIsBigEndian != 0
        let nonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let bytes = Int(asbd.mBitsPerChannel / 8)
        let inChannels = Int(asbd.mChannelsPerFrame)
        let outChannels = Int(format.channelCount)
        guard bytes == 2 || bytes == 4 else { return nil }

        func sample(_ offset: Int) -> Float {
            guard offset + bytes <= raw.count else { return 0 }
            if bytes == 2 {
                let u = bigEndian ? UInt16(raw[offset]) << 8 | UInt16(raw[offset + 1])
                                  : UInt16(raw[offset + 1]) << 8 | UInt16(raw[offset])
                return Float(Int16(bitPattern: u)) / 32768
            }
            var u: UInt32 = 0
            for i in 0..<4 { u |= UInt32(raw[offset + i]) << (bigEndian ? UInt32(24 - 8 * i) : UInt32(8 * i)) }
            return isFloat ? Float(bitPattern: u) : Float(Int32(bitPattern: u)) / 2_147_483_648
        }

        for c in 0..<outChannels {
            let src = min(c, inChannels - 1)
            let ch = dst[c]
            for f in 0..<frames {
                let offset = nonInterleaved ? (src * frames + f) * bytes : (f * inChannels + src) * bytes
                ch[f] = sample(offset)
            }
        }
        return out
    }

    // MARK: - fMP4 audio

    static func audioSpecificConfig(sampleRate: Double, channels: Int) -> [UInt8] {
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000]
        let idx = UInt16(rates.firstIndex(of: sampleRate) ?? 3)
        let v: UInt16 = (2 << 11) | (idx << 7) | (UInt16(channels) << 3)   // AAC-LC
        return [UInt8(v >> 8), UInt8(v & 0xFF)]
    }

    static func initSegment(sampleRate: UInt32, channels: UInt16, asc: [UInt8], bitrate: UInt32) -> Data {
        typealias M = FMP4Muxer
        var ftypP = Data()
        ftypP.fourCC("isom"); ftypP.be32(0x200)
        ftypP.fourCC("isom"); ftypP.fourCC("iso6"); ftypP.fourCC("mp41")
        let ftyp = M.box("ftyp", ftypP)

        var mvhdP = Data()
        mvhdP.be32(0); mvhdP.be32(0); mvhdP.be32(1000); mvhdP.be32(0)
        mvhdP.be32(0x0001_0000); mvhdP.be16(0x0100); mvhdP.zeros(10); mvhdP.matrix(); mvhdP.zeros(24)
        mvhdP.be32(2)
        let mvhd = M.fullBox("mvhd", 0, 0, mvhdP)

        var tkhdP = Data()
        tkhdP.be32(0); tkhdP.be32(0); tkhdP.be32(1); tkhdP.be32(0); tkhdP.be32(0); tkhdP.zeros(8)
        tkhdP.be16(0); tkhdP.be16(0); tkhdP.be16(0x0100); tkhdP.be16(0)
        tkhdP.matrix(); tkhdP.be32(0); tkhdP.be32(0)
        let tkhd = M.fullBox("tkhd", 0, 0x000003, tkhdP)

        var mdhdP = Data()
        mdhdP.be32(0); mdhdP.be32(0); mdhdP.be32(sampleRate); mdhdP.be32(0); mdhdP.be16(0x55C4); mdhdP.be16(0)
        let mdhd = M.fullBox("mdhd", 0, 0, mdhdP)

        var hdlrP = Data()
        hdlrP.be32(0); hdlrP.fourCC("soun"); hdlrP.zeros(12)
        hdlrP.append(contentsOf: Array("SoundHandler".utf8)); hdlrP.append(0)
        let hdlr = M.fullBox("hdlr", 0, 0, hdlrP)

        var smhdP = Data(); smhdP.be16(0); smhdP.be16(0)
        let smhd = M.fullBox("smhd", 0, 0, smhdP)
        var drefP = Data(); drefP.be32(1); drefP.append(M.fullBox("url ", 0, 1, Data()))
        let dinf = M.box("dinf", M.fullBox("dref", 0, 0, drefP))

        // esds : ES_Descriptor > DecoderConfigDescriptor > DecoderSpecificInfo (ASC) + SLConfig
        var dsi = Data([0x05, UInt8(asc.count)]); dsi.append(contentsOf: asc)
        var dcd = Data([0x40, 0x15, 0, 0, 0]); dcd.be32(bitrate); dcd.be32(bitrate); dcd.append(dsi)
        var dcdBox = Data([0x04, UInt8(dcd.count)]); dcdBox.append(dcd)
        var es = Data([0, 0, 0]); es.append(dcdBox); es.append(contentsOf: [0x06, 0x01, 0x02])
        var esBox = Data([0x03, UInt8(es.count)]); esBox.append(es)
        let esds = M.fullBox("esds", 0, 0, esBox)

        var mp4aP = Data()
        mp4aP.zeros(6); mp4aP.be16(1)
        mp4aP.zeros(8)
        mp4aP.be16(channels); mp4aP.be16(16); mp4aP.be16(0); mp4aP.be16(0)
        mp4aP.be32(sampleRate << 16)
        mp4aP.append(esds)
        let mp4a = M.box("mp4a", mp4aP)

        var stsdP = Data(); stsdP.be32(1); stsdP.append(mp4a)
        var empty = Data(); empty.be32(0)
        var stszP = Data(); stszP.be32(0); stszP.be32(0)
        let stbl = M.box("stbl", [M.fullBox("stsd", 0, 0, stsdP), M.fullBox("stts", 0, 0, empty),
                                  M.fullBox("stsc", 0, 0, empty), M.fullBox("stsz", 0, 0, stszP),
                                  M.fullBox("stco", 0, 0, empty)])
        let minf = M.box("minf", [smhd, dinf, stbl])
        let mdia = M.box("mdia", [mdhd, hdlr, minf])
        let trak = M.box("trak", [tkhd, mdia])
        var trexP = Data(); trexP.be32(1); trexP.be32(1); trexP.be32(0); trexP.be32(0); trexP.be32(0)
        let mvex = M.box("mvex", M.fullBox("trex", 0, 0, trexP))
        return ftyp + M.box("moov", [mvhd, trak, mvex])
    }

    static func fragment(packets: [Data], sequence: UInt32, baseDecodeTime: UInt64) -> Data {
        typealias M = FMP4Muxer
        func moof(dataOffset: UInt32) -> Data {
            var mfhdP = Data(); mfhdP.be32(sequence)
            var tfhdP = Data(); tfhdP.be32(1)
            var tfdtP = Data(); tfdtP.be64(baseDecodeTime)
            var trunP = Data()
            trunP.be32(UInt32(packets.count)); trunP.be32(dataOffset)
            for p in packets { trunP.be32(1024); trunP.be32(UInt32(p.count)) }
            let traf = M.box("traf", [M.fullBox("tfhd", 0, 0x020000, tfhdP),
                                      M.fullBox("tfdt", 1, 0, tfdtP),
                                      M.fullBox("trun", 0, 0x000301, trunP)])   // offset|duration|size
            return M.box("moof", [M.fullBox("mfhd", 0, 0, mfhdP), traf])
        }
        let total = packets.reduce(0) { $0 + $1.count }
        let size = moof(dataOffset: 0).count
        var out = moof(dataOffset: UInt32(size + 8))
        out.be32(UInt32(8 + total)); out.fourCC("mdat")
        for p in packets { out.append(p) }
        return out
    }
}
