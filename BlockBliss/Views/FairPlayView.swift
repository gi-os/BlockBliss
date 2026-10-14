import SwiftUI

/// The Fair Play promise in plain language, the exact scoring rules, and how pieces are chosen.
/// Numbers are read from `Scoring` and `PieceGenerator` so this page can never drift from the engine.
struct FairPlayView: View {
    @Environment(GameViewModel.self) private var vm

    var body: some View {
        let state = vm.state
        let difficulty = PieceGenerator.difficulty(score: state.score, round: state.round)

        List {
            Section {
                Text("Block Bliss follows the same rules for everyone, every time. This page says exactly what the game does, and what it never does.")
                    .font(.callout)
            }

            Section("Our promises") {
                promise("square.grid.3x3.fill", "Every set of 3 can be placed",
                        "When three pieces are dealt, the game has already proved that all three fit on the board in some order, counting the lines cleared in between. You can still lose by placing badly. That is the game.")
                promise("chart.line.uptrend.xyaxis", "Difficulty only follows this game",
                        "Harder pieces appear as this game's score and rounds grow. The game never looks at your best score, your history or how long you play.")
                promise("nosign", "No ads, revives or purchases",
                        "Nothing to watch, buy or unlock. No accounts, notifications or analytics, and the game never connects to the internet.")
                promise("heart.slash.fill", "No pressure",
                        "No streak rewards, timers or \"almost there\" messages. The next game starts only when you tap Play Again.")
                promise("arrow.clockwise.circle.fill", "A saved game is not re-rolled",
                        "Close the app and come back: you get the same board and the same pieces. Nothing is re-dealt.")
                promise("number.circle.fill", "Every game can be replayed",
                        "The seed is shown on the game-over screen. The same seed with the same moves deals the same pieces.")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("This game's difficulty")
                        Spacer()
                        Text("\(Int((difficulty * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    DifficultyMeter(value: difficulty)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("This game's difficulty")
                .accessibilityValue("\(Int((difficulty * 100).rounded())) percent")

                bullet("Trays are drawn from 41 piece orientations in 15 families. Small pieces such as dots, dominoes and little corners are common at first; squares, big corners and long bars become more common as the game goes on.")
                bullet("Each candidate tray is checked by a solver. Only a tray with a proven way to place all three is dealt.")
                bullet("Only two things look at your board: that check, and a small early-game preference for trays that allow a satisfying clear. The preference fades to zero as difficulty rises, and nothing ever picks a tray because it is harder on your board.")
                bullet("If no drawn tray passes the check, an easier tray is used. Three single blocks always fit, so the game can never get stuck.")
                bullet("Colours are random and have nothing to do with the shapes.")
            } header: {
                Text("How pieces are chosen")
            } footer: {
                Text("The meter shows the difficulty used for the next tray. It starts low and levels off at 100%.")
            }

            Section("Scoring rules") {
                rule("Placing a piece", "+1 point for each block in the piece.")
                rule("Clearing lines", "L(n) \u{00D7} (C + 1), where n is the number of rows and columns cleared by one placement and C is your combo before that move.")
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(1...6, id: \.self) { n in
                        HStack {
                            Text("\(n) \(n == 1 ? "line" : "lines")")
                            Spacer()
                            Text("L(\(n)) = \(Scoring.lineValue(n))").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
                rule("Combo", "A clearing move raises your combo by 1. The combo survives up to \(Scoring.comboWindow - 1) placements in a row that clear nothing, counted across trays. The \(ordinal(Scoring.comboWindow)) one in a row resets it to 0.")
                rule("All Clear", "Emptying the whole board adds a flat +\(Scoring.allClearBonus). The combo does not multiply it.")
                rule("Praise words", "2 lines Good!, 3 Great!, 4 Excellent!, 5 Amazing!, 6 Incredible!, and an empty board Unbelievable!. They are just words and do not change the score.")
                rule("Best score", "Kept on this device only. It is never sent anywhere and never used to choose pieces.")
            }
        }
        .navigationTitle("Fair Play promise")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Pieces of the page

    private func promise(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color(hex: 0x4BE35A))
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func bullet(_ text: String) -> some View {
        Text(text).font(.callout)
    }

    private func rule(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func ordinal(_ n: Int) -> String {
        switch n {
        case 1: return "first"
        case 2: return "second"
        case 3: return "third"
        default: return "\(n)th"
        }
    }
}

/// A slim horizontal bar from green (easy) to red (hard) with a marker at the current difficulty.
private struct DifficultyMeter: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: [Color(hex: 0x4BE35A), Color(hex: 0xF5BF06), Color(hex: 0xE04844)],
                                         startPoint: .leading, endPoint: .trailing))
                    .opacity(0.35)
                Capsule()
                    .fill(LinearGradient(colors: [Color(hex: 0x4BE35A), Color(hex: 0xF5BF06), Color(hex: 0xE04844)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(10, geo.size.width * value))
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(radius: 2)
                    .offset(x: max(0, geo.size.width * value - 14))
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}
