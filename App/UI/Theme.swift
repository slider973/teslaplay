import SwiftUI

/// Jetons de design : sombre premium + rouge d'action (UI/UX Pro Max), composants natifs iOS.
enum Theme {
    /// Rouge d'action, utilisé avec parcimonie (une action principale par écran).
    static let accent = Color(red: 0.89, green: 0.10, blue: 0.22)
    static let background = BackgroundStyle()
    static let surface = AnyShapeStyle(BackgroundStyle().secondary)
    static let cornerRadius: CGFloat = 20
    static let spacing: CGFloat = 16
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.spacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.cornerRadius))
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}
