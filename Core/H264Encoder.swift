import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Encodeur H.264 matériel (VideoToolbox), temps réel, sans B-frames, keyframe ≤ 1 s.
/// VideoToolbox redimensionne lui-même l'image source vers la taille de session (720p) :
/// aucun buffer intermédiaire n'est alloué par nous.
final class H264Encoder {
    var onInit: ((FMP4Muxer.InitSegment) -> Void)?
    var onFragment: ((Data, Bool) -> Void)?

    private let maxSize: (Int, Int)
    private let fps: Int
    private let bitrate: Int
    private var session: VTCompressionSession?
    private var width = 0
    private var height = 0
    private let muxer = FMP4Muxer()
    private let lock = NSLock()
    private var forceKeyframe = false

    /// `maxSize` : boîte (grand côté, petit côté) dans laquelle l'image est inscrite, quelle que
    /// soit l'orientation. 1920×1080 reste dans le niveau H.264 4.x décodable par la voiture.
    init(maxSize: (Int, Int) = (1280, 720), fps: Int = 30, bitrate: Int = 3_000_000) {
        self.maxSize = maxSize
        self.fps = fps
        self.bitrate = bitrate
    }

    deinit { invalidate() }

    func requestKeyframe() {
        lock.lock(); forceKeyframe = true; lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let (w, h) = Self.targetSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                     height: CVPixelBufferGetHeight(pixelBuffer),
                                     maxLong: maxSize.0, maxShort: maxSize.1)
        if session == nil || w != width || h != height {
            invalidate()
            createSession(width: w, height: h)
        }
        guard let session else { return }

        lock.lock()
        let force = forceKeyframe
        forceKeyframe = false
        lock.unlock()
        let props: CFDictionary? = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil

        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props,
                                        infoFlagsOut: nil) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else { return }
            self.handle(sampleBuffer)
        }
    }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    /// Taille cible : inscrite dans maxLong×maxShort, dimensions paires, jamais d'agrandissement.
    static func targetSize(width: Int, height: Int, maxLong: Int, maxShort: Int) -> (Int, Int) {
        let long = Double(max(1, max(width, height))), short = Double(max(1, min(width, height)))
        let scale = min(1.0, Double(maxLong) / long, Double(maxShort) / short)
        let w = Int((Double(width) * scale).rounded()) & ~1
        let h = Int((Double(height) * scale).rounded()) & ~1
        return (max(2, w), max(2, h))
    }

    private func createSession(width w: Int, height h: Int) {
        var lowLatency = true
        var newSession: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        var status = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &newSession)
        if status != noErr || newSession == nil {
            // Repli : encodeur matériel standard (sans le mode "low latency" d'iOS 14.5+).
            lowLatency = false
            status = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &newSession)
        }
        guard status == noErr, let s = newSession else {
            NSLog("[TeslaMirror] VTCompressionSessionCreate a échoué: \(status)")
            return
        }

        // Profil Baseline : pas de B-frames, avcC simple (sans extension High), décodable partout.
        let profile = lowLatency ? kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel : kVTProfileLevel_H264_Baseline_AutoLevel
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue!,
            kVTCompressionPropertyKey_ProfileLevel: profile,
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse!,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1.0,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
        ]
        for (key, value) in props {
            let st = VTSessionSetProperty(s, key: key, value: value as CFTypeRef)
            if st != noErr { NSLog("[TeslaMirror] propriété \(key) refusée: \(st)") }
        }
        // Plafond de débit (octets/s sur 1 s) — ignoré si non supporté.
        _ = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits,
                                 value: [bitrate * 3 / 2 / 8, 1] as CFArray)
        VTCompressionSessionPrepareToEncodeFrames(s)

        session = s
        width = w
        height = h
        requestKeyframe()
        NSLog("[TeslaMirror] encodeur H.264 \(w)x\(h) lowLatency=\(lowLatency)")
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        }

        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let copyStatus = data.withUnsafeMutableBytes { raw -> OSStatus in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copyStatus == noErr else { return }

        var sps: [UInt8]?
        var pps: [UInt8]?
        if isKeyframe {
            sps = Self.parameterSet(format, index: 0)
            pps = Self.parameterSet(format, index: 1)
        }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

        lock.lock()
        let result = muxer.mux(frame: data, isKeyframe: isKeyframe, ptsSeconds: pts.isFinite ? pts : 0,
                               sps: sps, pps: pps, width: Int(dims.width), height: Int(dims.height))
        lock.unlock()
        guard let result else { return }
        if let initSegment = result.initSegment { onInit?(initSegment) }
        onFragment?(result.fragment, isKeyframe)
    }

    private static func parameterSet(_ format: CMFormatDescription, index: Int) -> [UInt8]? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                                                                    parameterSetPointerOut: &pointer,
                                                                    parameterSetSizeOut: &size,
                                                                    parameterSetCountOut: nil,
                                                                    nalUnitHeaderLengthOut: nil)
        guard st == noErr, let pointer, size > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: pointer, count: size))
    }
}
