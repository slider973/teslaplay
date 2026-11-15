import Foundation

/// Muxeur MP4 fragmenté (ISO BMFF) minimal pour un unique flux H.264.
/// Chaque image encodée devient un fragment `moof`+`mdat` autonome (latence minimale).
/// La timeline produite est contiguë : Chrome/MSE se bloque sur les trous de timestamps.
final class FMP4Muxer {
    static let timescale: UInt32 = 90_000

    struct InitSegment {
        let codec: String   // ex. "avc1.42e01f"
        let data: Data
        let width: Int
        let height: Int
    }

    private var sps: [UInt8] = []
    private var pps: [UInt8] = []
    private var sequence: UInt32 = 0
    private var decodeTime: UInt64 = 0
    private var lastPTS: Double?
    private(set) var hasInit = false

    /// Ajoute une image encodée (format AVCC : NALU préfixés par leur longueur sur 4 octets).
    /// Retourne éventuellement un nouvel init segment (à envoyer AVANT le fragment), puis le fragment.
    func mux(frame: Data, isKeyframe: Bool, ptsSeconds: Double,
             sps newSPS: [UInt8]?, pps newPPS: [UInt8]?, width: Int, height: Int)
        -> (initSegment: InitSegment?, fragment: Data)? {

        var newInit: InitSegment?
        if isKeyframe, let s = newSPS, let p = newPPS, s.count >= 4, !p.isEmpty, (s != sps || p != pps || !hasInit) {
            sps = s
            pps = p
            hasInit = true
            newInit = InitSegment(codec: Self.codecString(sps: s),
                                  data: Self.initSegment(sps: s, pps: p, width: width, height: height),
                                  width: width, height: height)
        }
        guard hasInit else { return nil } // Pas d'init : on attend une keyframe.

        // Durée de l'échantillon = intervalle réel depuis l'image précédente, bornée.
        // Une pause (écran statique) est donc "compressée" : pas de trou dans la timeline.
        var duration = 1.0 / 30.0
        if let last = lastPTS {
            duration = min(max(ptsSeconds - last, 1.0 / 120.0), 0.1)
        }
        lastPTS = ptsSeconds
        let ticks = UInt32((duration * Double(Self.timescale)).rounded())

        sequence &+= 1
        let fragment = Self.fragment(sample: frame, isKeyframe: isKeyframe, sequence: sequence,
                                     baseDecodeTime: decodeTime, duration: ticks)
        decodeTime += UInt64(ticks)
        return (newInit, fragment)
    }

    // MARK: - Boîtes

    static func codecString(sps: [UInt8]) -> String {
        String(format: "avc1.%02x%02x%02x", sps[1], sps[2], sps[3])
    }

    static func initSegment(sps: [UInt8], pps: [UInt8], width: Int, height: Int) -> Data {
        let w = UInt16(clamping: width), h = UInt16(clamping: height)

        var ftypP = Data()
        ftypP.fourCC("isom"); ftypP.be32(0x200)
        ftypP.fourCC("isom"); ftypP.fourCC("iso6"); ftypP.fourCC("avc1"); ftypP.fourCC("mp41")
        let ftyp = box("ftyp", ftypP)

        var mvhdP = Data()
        mvhdP.be32(0); mvhdP.be32(0)            // creation / modification
        mvhdP.be32(1000); mvhdP.be32(0)         // timescale / duration
        mvhdP.be32(0x0001_0000)                 // rate 1.0
        mvhdP.be16(0x0100)                      // volume 1.0
        mvhdP.zeros(10)
        mvhdP.matrix()
        mvhdP.zeros(24)
        mvhdP.be32(2)                           // next_track_ID
        let mvhd = fullBox("mvhd", 0, 0, mvhdP)

        var tkhdP = Data()
        tkhdP.be32(0); tkhdP.be32(0)            // creation / modification
        tkhdP.be32(1)                           // track_ID
        tkhdP.be32(0)                           // reserved
        tkhdP.be32(0)                           // duration
        tkhdP.zeros(8)
        tkhdP.be16(0); tkhdP.be16(0)            // layer / alternate_group
        tkhdP.be16(0); tkhdP.be16(0)            // volume / reserved
        tkhdP.matrix()
        tkhdP.be32(UInt32(w) << 16); tkhdP.be32(UInt32(h) << 16)
        let tkhd = fullBox("tkhd", 0, 0x000003, tkhdP)

        var mdhdP = Data()
        mdhdP.be32(0); mdhdP.be32(0)
        mdhdP.be32(timescale); mdhdP.be32(0)
        mdhdP.be16(0x55C4)                      // langue "und"
        mdhdP.be16(0)
        let mdhd = fullBox("mdhd", 0, 0, mdhdP)

        var hdlrP = Data()
        hdlrP.be32(0); hdlrP.fourCC("vide"); hdlrP.zeros(12)
        hdlrP.append(contentsOf: Array("VideoHandler".utf8)); hdlrP.append(0)
        let hdlr = fullBox("hdlr", 0, 0, hdlrP)

        var vmhdP = Data(); vmhdP.be16(0); vmhdP.zeros(6)
        let vmhd = fullBox("vmhd", 0, 1, vmhdP)

        var drefP = Data(); drefP.be32(1); drefP.append(fullBox("url ", 0, 1, Data()))
        let dinf = box("dinf", fullBox("dref", 0, 0, drefP))

        var avcCP = Data()
        avcCP.append(1)                         // configurationVersion
        avcCP.append(sps[1]); avcCP.append(sps[2]); avcCP.append(sps[3])
        avcCP.append(0xFF)                      // lengthSizeMinusOne = 3
        avcCP.append(0xE1)                      // 1 SPS
        avcCP.be16(UInt16(sps.count)); avcCP.append(contentsOf: sps)
        avcCP.append(1)                         // 1 PPS
        avcCP.be16(UInt16(pps.count)); avcCP.append(contentsOf: pps)
        let avcC = box("avcC", avcCP)

        var avc1P = Data()
        avc1P.zeros(6); avc1P.be16(1)           // data_reference_index
        avc1P.be16(0); avc1P.be16(0); avc1P.zeros(12)
        avc1P.be16(w); avc1P.be16(h)
        avc1P.be32(0x0048_0000); avc1P.be32(0x0048_0000) // 72 dpi
        avc1P.be32(0)
        avc1P.be16(1)                           // frame_count
        avc1P.zeros(32)                         // compressorname
        avc1P.be16(0x0018)                      // depth
        avc1P.be16(0xFFFF)                      // pre_defined = -1
        avc1P.append(avcC)
        let avc1 = box("avc1", avc1P)

        var stsdP = Data(); stsdP.be32(1); stsdP.append(avc1)
        var empty = Data(); empty.be32(0)
        var stszP = Data(); stszP.be32(0); stszP.be32(0)
        let stbl = box("stbl", [fullBox("stsd", 0, 0, stsdP),
                                fullBox("stts", 0, 0, empty),
                                fullBox("stsc", 0, 0, empty),
                                fullBox("stsz", 0, 0, stszP),
                                fullBox("stco", 0, 0, empty)])
        let minf = box("minf", [vmhd, dinf, stbl])
        let mdia = box("mdia", [mdhd, hdlr, minf])
        let trak = box("trak", [tkhd, mdia])

        var trexP = Data()
        trexP.be32(1); trexP.be32(1); trexP.be32(0); trexP.be32(0); trexP.be32(0)
        let mvex = box("mvex", fullBox("trex", 0, 0, trexP))

        let moov = box("moov", [mvhd, trak, mvex])
        return ftyp + moov
    }

    static func fragment(sample: Data, isKeyframe: Bool, sequence: UInt32,
                         baseDecodeTime: UInt64, duration: UInt32) -> Data {
        // sample_flags : keyframe = "ne dépend d'aucune autre image" ; sinon "dépend + non-sync".
        let flags: UInt32 = isKeyframe ? 0x0200_0000 : 0x0101_0000

        func moof(dataOffset: UInt32) -> Data {
            var mfhdP = Data(); mfhdP.be32(sequence)
            var tfhdP = Data(); tfhdP.be32(1)
            var tfdtP = Data(); tfdtP.be64(baseDecodeTime)
            var trunP = Data()
            trunP.be32(1)                       // sample_count
            trunP.be32(dataOffset)
            trunP.be32(duration)
            trunP.be32(UInt32(sample.count))
            trunP.be32(flags)
            let traf = box("traf", [fullBox("tfhd", 0, 0x020000, tfhdP),   // default-base-is-moof
                                    fullBox("tfdt", 1, 0, tfdtP),
                                    fullBox("trun", 0, 0x000701, trunP)])  // offset|duration|size|flags
            return box("moof", [fullBox("mfhd", 0, 0, mfhdP), traf])
        }

        let size = moof(dataOffset: 0).count     // taille constante, indépendante de l'offset
        var out = moof(dataOffset: UInt32(size + 8))
        out.be32(UInt32(8 + sample.count))
        out.fourCC("mdat")
        out.append(sample)
        return out
    }

    // MARK: - Helpers

    static func box(_ type: String, _ payload: Data) -> Data { box(type, [payload]) }

    static func box(_ type: String, _ parts: [Data]) -> Data {
        let size = 8 + parts.reduce(0) { $0 + $1.count }
        var d = Data(capacity: size)
        d.be32(UInt32(size))
        d.fourCC(type)
        for p in parts { d.append(p) }
        return d
    }

    static func fullBox(_ type: String, _ version: UInt8, _ flags: UInt32, _ payload: Data) -> Data {
        var h = Data()
        h.append(version)
        h.append(UInt8((flags >> 16) & 0xFF)); h.append(UInt8((flags >> 8) & 0xFF)); h.append(UInt8(flags & 0xFF))
        return box(type, [h, payload])
    }
}

extension Data {
    mutating func be16(_ v: UInt16) { append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)]) }
    mutating func be32(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
    mutating func be64(_ v: UInt64) { be32(UInt32(v >> 32)); be32(UInt32(v & 0xFFFF_FFFF)) }
    mutating func fourCC(_ s: String) { append(contentsOf: Array(s.utf8.prefix(4))) }
    mutating func zeros(_ n: Int) { append(contentsOf: [UInt8](repeating: 0, count: n)) }
    mutating func matrix() {
        for v: UInt32 in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] { be32(v) }
    }
}
