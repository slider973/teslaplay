import SwiftUI

/// Trois onglets : l'essentiel (Recopie), les sources lues par la voiture (Médias) et
/// l'outillage technique (Diagnostic), pour garder l'écran principal simple.
struct ContentView: View {
    @State private var model = MirrorStatusModel()
    @State private var tunnel = TunnelController()
    @State private var localNetwork = LocalNetworkPermission()
    /// Onglet mémorisé par scène (fenêtre).
    @SceneStorage("tab") private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            MirrorHomeView()
                .tabItem { Label("Recopie", systemImage: "rectangle.on.rectangle") }
                .tag(0)
            MediaView()
                .tabItem { Label("Médias", systemImage: "play.tv") }
                .tag(1)
            DiagnosticsView()
                .tabItem { Label("Diagnostic", systemImage: "stethoscope") }
                .tag(2)
        }
        .tint(Theme.accent)
        .environment(model)
        .environment(tunnel)
        .environment(localNetwork)
        .task { await model.poll() }
        .onAppear {
            localNetwork.request()
            // Pas de verrouillage auto tant que l'app est au premier plan.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

#Preview { ContentView() }
