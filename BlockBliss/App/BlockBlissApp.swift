import SwiftUI

@main
struct BlockBlissApp: App {
    @State private var settings: Settings
    @State private var viewModel: GameViewModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Settings first: it pushes the sound / vibration switches into the audio and haptics engines.
        let settings = Settings()
        _settings = State(initialValue: settings)
        _viewModel = State(initialValue: GameViewModel(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            GameView()
                .environment(viewModel)
                .environment(settings)
                // Dark-ish theme regardless of the system appearance; also gives a light status bar.
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            // Save on the way out; the run is also saved after every move.
            if phase != .active { viewModel.appWillResignActive() }
        }
    }
}
