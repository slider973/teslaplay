import Foundation
import CoreMedia
import CoreVideo

/// Point d'entrée unique utilisé par l'extension (et le harnais de test macOS) :
/// reçoit les images, les cadence et les distribue aux encodeurs puis au serveur.
final class MirrorPipeline {
    static let mjpegFPS = 12.0
    static let mjpegIdleFPS = 1.0   // garde un JPEG récent en cache même sans client
    static let h264FPS = 30.0

    let server: MirrorServer
    private let jpegEncoder = JPEGEncoder(quality: 0.5, shortSide: 720)
    private let h264Encoder = H264Encoder(shortSide: 720, fps: Int(MirrorPipeline.h264FPS), bitrate: 3_000_000)
    private var lastJPEGTime = -Double.infinity
    private var lastH264Time = -Double.infinity
    private var frameCount = 0

    /// Observateurs de débogage (harnais de test).
    var onInitSegment: ((FMP4Muxer.InitSegment) -> Void)?
    var onFragment: ((Data, Bool) -> Void)?

    init(port: UInt16 = 8080) {
        server = MirrorServer(port: port)
        h264Encoder.onInit = { [weak self] segment in
            self?.server.publishInit(segment)
            self?.onInitSegment?(segment)
        }
        h264Encoder.onFragment = { [weak self] data, isKey in
            self?.server.publishFragment(data, isKeyframe: isKey)
            self?.onFragment?(data, isKey)
        }
        server.onKeyframeNeeded = { [weak h264Encoder] in h264Encoder?.requestKeyframe() }
    }

    func start(onFailure: @escaping (Error) -> Void) throws {
        try server.start(onFailure: onFailure)
    }

    func stop() {
        h264Encoder.invalidate()
        server.stop()
    }

    /// À appeler pour chaque image ReplayKit. `rotation` en degrés horaires (0/90/180/270)
    /// à appliquer côté navigateur. Le pixel buffer n'est jamais retenu au-delà de l'appel
    /// (VideoToolbox le relâche dès l'encodage terminé).
    func process(pixelBuffer: CVPixelBuffer, rotation: Int, pts: CMTime) {
        server.rotation = rotation
        let now = ProcessInfo.processInfo.systemUptime
        frameCount += 1
        let status = SharedStatus.shared
        status.set("frames", frameCount)
        status.set("clients", server.clientCountSnapshot)
        status.set("memoryMB", SharedStatus.memoryFootprintMB())
        status.flush(throttled: true)
        let tolerance = 0.004

        // Sans client miroir : 1 i/s seulement (garde un GOP récent en cache, économise la batterie).
        let h264FPS = server.hasMirrorClients ? Self.h264FPS : 1.0
        if now - lastH264Time >= 1.0 / h264FPS - tolerance {
            lastH264Time = now
            h264Encoder.encode(pixelBuffer, pts: pts)
        }

        let jpegFPS = server.hasMJPEGClients ? Self.mjpegFPS : Self.mjpegIdleFPS
        if now - lastJPEGTime >= 1.0 / jpegFPS - tolerance {
            lastJPEGTime = now
            if let jpeg = jpegEncoder.encode(pixelBuffer) { server.publishJPEG(jpeg) }
        }
    }
}
