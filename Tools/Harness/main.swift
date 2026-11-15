// Harnais de test macOS : fait tourner le code de Core/ (serveur + encodeurs) avec des images
// synthétiques, sans ReplayKit. Usage : Tools/run-harness.sh [port] [secondes] [fichier.mp4]
import Foundation
import CoreMedia
import CoreVideo

let args = CommandLine.arguments
let port = UInt16(args.count > 1 ? args[1] : "8099") ?? 8099
let seconds = Double(args.count > 2 ? args[2] : "60") ?? 60
let dumpPath = args.count > 3 ? args[3] : nil

let pipeline = MirrorPipeline(port: port)
let env = ProcessInfo.processInfo.environment
// Lecteur intégré : fichiers statiques + configuration média (à la place de l'App Group).
pipeline.server.webRoot = URL(fileURLWithPath: env["TM_WEBROOT"] ?? "Web")
if let dir = env["TM_MEDIA_DIR"] {
    let mediaDir = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
    MediaConfig.overrideDirectory = mediaDir
    if let m3u = env["TM_M3U"] {
        let source = m3u.hasPrefix("http") ? URL(string: m3u)! : URL(fileURLWithPath: m3u)
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                var local = source
                if !source.isFileURL { local = try await URLSession.shared.download(from: source).0 }
                let r = try await M3UParser.parse(fileAt: local, outputDirectory: mediaDir)
                print("M3U : \(r.channels) chaînes, \(r.groups) groupes")
            } catch { print("M3U erreur : \(error)") }
            sem.signal()
        }
        sem.wait()
    }
}
// Jellyfin de test : TM_JF="https://serveur|utilisateur|motdepasse"
if let jfSpec = env["TM_JF"], MediaConfig.overrideDirectory != nil {
    let parts = jfSpec.components(separatedBy: "|")
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let cfg = try await JellyfinAuth.login(server: parts[0], username: parts.count > 1 ? parts[1] : "",
                                                   password: parts.count > 2 ? parts[2] : "", deviceId: "tm-harness")
            MediaConfig.saveJellyfin(cfg)
            print("Jellyfin : connecté à \(cfg.name)")
        } catch { print("Jellyfin erreur : \(error)") }
        sem.signal()
    }
    sem.wait()
}
// Connexion rapide de test : TM_JF_QC="https://serveur|utilisateur|motdepasse" ; l'approbation
// est faite par une 2e session (connexion par mot de passe) qui simule l'autre appareil.
if let spec = env["TM_JF_QC"], MediaConfig.overrideDirectory != nil {
    let p = spec.components(separatedBy: "|")
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let qc = try await JellyfinAuth.initiateQuickConnect(server: p[0], deviceId: "tm-harness-qc")
            print("Connexion rapide : code \(qc.code)")
            print("approuvé avant validation ? \(try await JellyfinAuth.quickConnectApproved(server: p[0], secret: qc.secret, deviceId: "tm-harness-qc"))")
            let other = try await JellyfinAuth.login(server: p[0], username: p[1], password: p.count > 2 ? p[2] : "", deviceId: "tm-other-device")
            var r = URLRequest(url: URL(string: other.uri + "/QuickConnect/Authorize?code=\(qc.code)&userId=\(other.userId)")!)
            r.httpMethod = "POST"
            r.setValue(JellyfinAuth.authorizationHeader(deviceId: "tm-other-device", token: other.token), forHTTPHeaderField: "Authorization")
            let (_, resp) = try await URLSession.shared.data(for: r)
            print("validation par l'autre appareil : HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
            var ok = false
            for _ in 0..<10 where !ok {
                ok = try await JellyfinAuth.quickConnectApproved(server: p[0], secret: qc.secret, deviceId: "tm-harness-qc")
                if !ok { try await Task.sleep(nanoseconds: 1_000_000_000) }
            }
            print("approuvé : \(ok)")
            let cfg = try await JellyfinAuth.completeQuickConnect(server: p[0], secret: qc.secret, deviceId: "tm-harness-qc")
            MediaConfig.saveJellyfin(cfg)
            print("Jellyfin (connexion rapide) : connecté à \(cfg.name), jeton \(cfg.token.isEmpty ? "absent" : "reçu")")
        } catch { print("Connexion rapide erreur : \(error)") }
        sem.signal()
    }
    sem.wait()
}
var dump = Data()
var initCount = 0, keyCount = 0, fragCount = 0
pipeline.onInitSegment = { s in
    initCount += 1
    print("init segment: codec=\(s.codec) \(s.width)x\(s.height) \(s.data.count) octets")
    if dump.isEmpty { dump.append(s.data) }
}
pipeline.onFragment = { d, k in
    fragCount += 1; if k { keyCount += 1 }
    if dumpPath != nil && dump.count < 20_000_000 { dump.append(d) }
}
try pipeline.start { error in print("ERREUR serveur: \(error)"); exit(1) }

// Buffer 1179x2556 (iPhone 15/16) en BGRA, motif animé.
let W = 1179, H = 2556
var pool: CVPixelBufferPool?
CVPixelBufferPoolCreate(nil, nil, [
    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey: W, kCVPixelBufferHeightKey: H,
    kCVPixelBufferIOSurfacePropertiesKey: [:],
] as CFDictionary, &pool)

func makeFrame(_ n: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &pb)
    let buf = pb!
    CVPixelBufferLockBaseAddress(buf, [])
    let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buf)
    let barY = (n * 12) % H
    for y in 0..<H {
        let row = base + y * stride
        let inBar = abs(y - barY) < 60
        for x in Swift.stride(from: 0, to: W, by: 1) {
            let p = row + x * 4
            if inBar { p[0] = 255; p[1] = 255; p[2] = 255 }
            else { p[0] = UInt8((x + n * 3) & 0xFF); p[1] = UInt8(y & 0xFF); p[2] = UInt8((n * 5) & 0xFF) }
            p[3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buf, [])
    return buf
}

print("Harnais sur http://127.0.0.1:\(port)  (\(Int(seconds)) s, cadence irrégulière + pauses)")
let start = Date()
var n = 0
let queue = DispatchQueue(label: "harness.frames")
queue.async {
    while Date().timeIntervalSince(start) < seconds {
        let t = Date().timeIntervalSince(start)
        // Toutes les 15 s : pause de 4 s (écran statique, comme ReplayKit).
        if t.truncatingRemainder(dividingBy: 15) > 11 { Thread.sleep(forTimeInterval: 0.05); continue }
        let pts = CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 1_000_000_000)
        autoreleasepool {
            pipeline.process(pixelBuffer: makeFrame(n), rotation: (Int(t) / 20 % 2) * 90, pts: pts)
        }
        n += 1
        // 60 fps avec gigue
        Thread.sleep(forTimeInterval: 1.0 / 60.0 + Double.random(in: -0.005...0.01))
    }
    Thread.sleep(forTimeInterval: 0.5)
    print("Fin : \(n) images fournies, \(fragCount) fragments (\(keyCount) keyframes), \(initCount) init")
    if let dumpPath {
        try? dump.write(to: URL(fileURLWithPath: dumpPath))
        print("fMP4 écrit : \(dumpPath) (\(dump.count) octets)")
    }
    pipeline.stop()
    exit(0)
}
dispatchMain()
