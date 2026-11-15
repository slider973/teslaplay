import SwiftUI
import ReplayKit

/// Le vrai RPSystemBroadcastPickerView est posé, quasi transparent, PAR-DESSUS le libellé
/// SwiftUI et étiré à sa taille : le toucher arrive directement sur le bouton système
/// (aucune astuce `sendActions` nécessaire).
struct BroadcastPicker: UIViewRepresentable {
    /// Bundle ID de l'extension = bundle ID de l'app + ".Broadcast" (voir project.yml).
    static var extensionBundleID: String {
        (Bundle.main.bundleIdentifier ?? "") + ".Broadcast"
    }

    func makeUIView(context: Context) -> StretchedPickerView {
        let picker = StretchedPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        picker.preferredExtension = Self.extensionBundleID
        picker.showsMicrophoneButton = false
        picker.alpha = 0.02 // < 0.01 désactiverait les touchers
        return picker
    }

    func updateUIView(_ uiView: StretchedPickerView, context: Context) {}
}

final class StretchedPickerView: RPSystemBroadcastPickerView {
    override func layoutSubviews() {
        super.layoutSubviews()
        for case let button as UIButton in subviews { button.frame = bounds }
    }
}
