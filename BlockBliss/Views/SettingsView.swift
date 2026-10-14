import SwiftUI

/// The settings sheet: feedback toggles, New Game, the Fair Play page, lifetime stats and the version.
/// Plain system controls so it follows Dynamic Type and VoiceOver without extra work.
struct SettingsView: View {
    @Environment(GameViewModel.self) private var vm
    @Environment(Settings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var confirmNewGame = false

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            List {
                Section {
                    Toggle("Sound", isOn: $settings.soundEnabled)
                    Toggle("Vibration", isOn: $settings.vibrationEnabled)
                    Toggle("Reduce Effects", isOn: $settings.reduceEffects)
                } header: {
                    Text("Feedback")
                } footer: {
                    Text("Reduce Effects means fewer particles, no screen shake and shorter animations. It follows the system Reduce Motion setting until you change it here.")
                }

                Section {
                    Button("New Game", role: .destructive) {
                        SoundEngine.shared.play(.tap)
                        Haptics.shared.tap()
                        confirmNewGame = true
                    }
                }

                Section {
                    NavigationLink {
                        FairPlayView()
                    } label: {
                        Label("Fair Play promise", systemImage: "checkmark.seal.fill")
                    }
                } footer: {
                    Text("What the game does, what it never does, and the exact scoring rules.")
                }

                Section("Stats") {
                    let r = vm.records
                    stat("Games played", r.gamesPlayed)
                    stat("Best score", vm.bestScore)
                    stat("Best combo", max(r.bestCombo, vm.state.bestComboThisGame))
                    stat("Total lines", r.totalLines)
                    stat("All Clears", r.allClears)
                    stat("Pieces placed", r.totalPieces)
                }

                Section {
                    LabeledContent("Version", value: Self.versionString)
                } header: {
                    Text("About")
                } footer: {
                    Text("No ads, purchases, accounts, notifications, analytics or tracking. The game never connects to the internet. Everything stays on this device.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Start a new game?", isPresented: $confirmNewGame, titleVisibility: .visible) {
                Button("New Game", role: .destructive) {
                    vm.newGame()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your current game will end. Your best score and stats are kept.")
            }
        }
        .preferredColorScheme(.dark)
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        LabeledContent(title) { Text(value, format: .number).monospacedDigit() }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
