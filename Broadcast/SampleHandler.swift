import ReplayKit
import CoreMedia
import ImageIO

/// Broadcast Upload Extension : c'est ici que vit le serveur HTTP, car l'app principale
/// est suspendue dès qu'elle passe en arrière-plan. Limite mémoire ≈ 50 Mo :
/// downscale 720p par VideoToolbox / Core Image, aucun buffer ReplayKit conservé.
final class SampleHandler: RPBroadcastSampleHandler {
    static let port: UInt16 = 8080
    private var pipeline: MirrorPipeline?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let status = SharedStatus.shared
        status.reset()
        status.set("broadcast", "started")
        status.set("listener", "starting")
        status.set("startedAt", Date().timeIntervalSince1970, flush: true)
        let pipeline = MirrorPipeline(port: Self.port)
        pipeline.server.webRoot = Bundle.main.url(forResource: "Web", withExtension: nil)
        do {
            try pipeline.start { [weak self] error in
                self?.fail("Le serveur n'a pas pu démarrer sur le port \(Self.port) : \(error.localizedDescription)")
            }
            self.pipeline = pipeline
        } catch {
            fail("Le serveur n'a pas pu démarrer : \(error.localizedDescription)")
        }
    }

    override func broadcastPaused() { SharedStatus.shared.set("broadcast", "paused", flush: true) }
    override func broadcastResumed() { SharedStatus.shared.set("broadcast", "started", flush: true) }

    override func broadcastFinished() {
        pipeline?.stop()
        pipeline = nil
        SharedStatus.shared.set("broadcast", "finished")
        SharedStatus.shared.set("listener", "stopped", flush: true)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        if sampleBufferType == .audioApp { pipeline?.process(audio: sampleBuffer); return }
        guard sampleBufferType == .video,
              let pipeline,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        pipeline.process(pixelBuffer: pixelBuffer,
                         rotation: Self.rotation(of: sampleBuffer),
                         pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    /// Rotation horaire (degrés) à appliquer à l'image pour l'afficher droite.
    /// Correspondance utilisée par l'intégration ReplayKit de Jitsi/WebRTC
    /// (.left → 90°, .down → 180°, .right → 270°). À valider sur appareil ;
    /// la page web propose de toute façon un bouton de rotation manuelle.
    private static func rotation(of sampleBuffer: CMSampleBuffer) -> Int {
        guard let number = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                           attachmentModeOut: nil) as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: number.uint32Value) else { return 0 }
        switch orientation {
        case .left, .leftMirrored: return 90
        case .down, .downMirrored: return 180
        case .right, .rightMirrored: return 270
        default: return 0
        }
    }

    private func fail(_ message: String) {
        NSLog("[TeslaMirror] \(message)")
        SharedStatus.shared.set("broadcast", "error: \(message)", flush: true)
        let error = NSError(domain: "TeslaMirror", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        finishBroadcastWithError(error)
    }
}
