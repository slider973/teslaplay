import Foundation
import Darwin

/// État de diagnostic partagé entre l'extension et l'app via l'App Group
/// (`group.<bundle ID de l'app>`), écrit dans `status.json`. Sans App Group (harnais macOS),
/// les écritures sont simplement ignorées.
final class SharedStatus {
    static let shared = SharedStatus()

    static var appGroupID: String {
        var id = Bundle.main.bundleIdentifier ?? ""
        if id.hasSuffix(".Broadcast") { id.removeLast(".Broadcast".count) }
        return "group." + id
    }

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("status.json")
    }

    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private var lastFlush = 0.0
    private let url = SharedStatus.fileURL

    func set(_ key: String, _ value: Any?, flush force: Bool = false) {
        lock.lock()
        values[key] = value ?? NSNull()
        lock.unlock()
        if force { flush() }
    }

    /// Écrit au plus une fois par seconde sauf `force`.
    func flush(throttled: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if throttled && now - lastFlush < 1 { lock.unlock(); return }
        lastFlush = now
        values["updatedAt"] = Date().timeIntervalSince1970
        let snapshot = values
        lock.unlock()
        guard let url, let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func reset() {
        lock.lock(); values = [:]; lock.unlock()
    }

    /// Empreinte mémoire réelle (celle que jetsam compare à la limite de ~50 Mo).
    static func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return (Double(info.phys_footprint) / 1_048_576 * 10).rounded() / 10
    }
}
