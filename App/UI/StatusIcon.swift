import SwiftUI

/// Indicateur d'état : icône + couleur (jamais la couleur seule).
struct StatusIcon: View {
    enum Kind { case ok, pending, warning, error }
    let kind: Kind

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .imageScale(.large)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch kind {
        case .ok: "checkmark.circle.fill"
        case .pending: "circle.dashed"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .ok: .green
        case .pending: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
