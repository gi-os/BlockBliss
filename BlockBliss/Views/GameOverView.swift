import SwiftUI

// MARK: - "No Space Left" band

/// Dark translucent navy band over the tray. The unplaceable pieces stay visible (dimmed) around it.
struct NoSpaceBand: View {
    let layout: GameLayout

    var body: some View {
        let height = min(layout.trayRect.height, 76)
        ZStack {
            Rectangle()
                .fill(Theme.navy.opacity(0.86))
                .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.12)).frame(height: 1) }
                .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.12)).frame(height: 1) }
            Text("No Space Left")
                .font(Theme.rounded(30))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 0, x: 0, y: 2)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(width: layout.trayRect.width, height: height)
        .offset(x: layout.trayRect.minX, y: layout.trayRect.midY - height / 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("No space left")
    }
}

// MARK: - Game-over card

/// Shown after the "No Space Left" band. Neutral copy only: no near-miss messages, no pressure, and it
/// never restarts on its own. A run that beats the previous best gets a purple card, a crown and confetti.
struct GameOverView: View {
    @Environment(GameViewModel.self) private var vm
    @Environment(Settings.self) private var settings
    @State private var appeared = false

    var body: some View {
        let state = vm.state
        let newBest = vm.isNewBest

        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            if newBest && !settings.reduceEffects {
                ConfettiView().ignoresSafeArea()
            }

            card(state: state, newBest: newBest)
                .padding(.horizontal, 20)
                .scaleEffect(appeared ? 1 : 0.85)
                .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(settings.reduceEffects ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.72)) {
                appeared = true
            }
        }
        .accessibilityAddTraits(.isModal)
    }

    private func card(state: GameState, newBest: Bool) -> some View {
        let gradient = newBest
            ? [Color(hex: 0xA766EE), Color(hex: 0x6A35C2)]
            : [Color(hex: 0x4D7BF2), Color(hex: 0x2B49BD)]

        return VStack(spacing: 14) {
            if newBest {
                Image(systemName: "crown.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(Theme.crown)
                    .shadow(color: .black.opacity(0.3), radius: 0, x: 0, y: 3)
                    .accessibilityHidden(true)
                Text("New Best!")
                    .font(Theme.rounded(30))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 0, x: 0, y: 2)
            } else {
                Text("Game Over")
                    .font(Theme.rounded(26))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.3), radius: 0, x: 0, y: 2)
            }

            VStack(spacing: 0) {
                Text("Score")
                    .font(Theme.rounded(18, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                Text("\(state.score)")
                    .font(Theme.rounded(64))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .shadow(color: .black.opacity(0.3), radius: 0, x: 0, y: 4)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Score")
            .accessibilityValue("\(state.score)")

            HStack(spacing: 8) {
                Text("Best")
                    .font(Theme.rounded(18, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                Text("\(vm.bestScore)")
                    .font(Theme.rounded(28))
                    .monospacedDigit()
                    .foregroundStyle(Theme.bestScore)
                    .shadow(color: .black.opacity(0.3), radius: 0, x: 0, y: 2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Best score")
            .accessibilityValue("\(vm.bestScore)")

            statsRow(state)

            Button {
                SoundEngine.shared.play(.tap)
                Haptics.shared.tap()
                vm.newGame()
            } label: {
                Text("Play Again")
                    .font(Theme.rounded(28))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 0, x: 0, y: 2)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            .buttonStyle(GreenButtonStyle())
            .padding(.top, 4)

            Text("Seed \(Self.seedText(state.seed))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .textSelection(.enabled)
                .accessibilityLabel("Seed \(Self.seedText(state.seed))")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .frame(maxWidth: 360)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.28), lineWidth: 2))
                .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
        )
    }

    private func statsRow(_ state: GameState) -> some View {
        HStack(spacing: 0) {
            stat("Lines", "\(state.linesCleared)")
            stat("Best combo", "\(state.bestComboThisGame)")
            stat("Pieces", "\(state.piecesPlaced)")
        }
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.18)))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(Theme.rounded(22))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    /// 16 hex digits, grouped for readability.
    static func seedText(_ seed: UInt64) -> String {
        let hex = String(format: "%016llX", seed)
        return stride(from: 0, to: 16, by: 4).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: "-")
    }
}

// MARK: - Buttons

/// Big glossy green button with a darker lip underneath, like the original.
struct GreenButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let lip: CGFloat = configuration.isPressed ? 2 : 6
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0x3EDB4F), Color(hex: 0x1DB233)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1.5))
                    .shadow(color: Color(hex: 0x0B6A1C), radius: 0, x: 0, y: lip)
            )
            .offset(y: configuration.isPressed ? 4 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .padding(.bottom, 6)
    }
}

// MARK: - Confetti

/// One-shot confetti burst for a new best. Particles are deterministic functions of time, drawn in a
/// single Canvas; the timeline pauses after the last piece has faded out.
private struct ConfettiView: View {
    @State private var start = Date()
    @State private var finished = false

    private static let colors: [Color] = BlockColor.allCases.map { $0.palette.face } + [.white]
    private static let count = 70
    private static let duration = 5.0

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: finished)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSince(start)
                for i in 0..<Self.count {
                    var rng = SeededRNG(seed: UInt64(i) &* 977 &+ 13)
                    let delay = rng.nextUnit() * 0.9
                    let tt = t - delay
                    guard tt > 0 else { continue }
                    let x0 = rng.nextUnit() * size.width
                    let fall = 150 + rng.nextUnit() * 140
                    let sway = 12 + rng.nextUnit() * 26
                    let swaySpeed = 2 + rng.nextUnit() * 3
                    let spin = (rng.nextUnit() - 0.5) * 12
                    let w = 6 + rng.nextUnit() * 6
                    let color = Self.colors[Int(rng.next() % UInt64(Self.colors.count))]

                    let x = x0 + sway * sin(swaySpeed * tt)
                    let y = -20 + fall * tt
                    let fade = 1 - ((tt - (Self.duration - 1.5)) / 1.2).clamped(0, 1)
                    guard fade > 0, y < size.height + 20 else { continue }

                    var s = ctx
                    s.opacity = fade
                    s.translateBy(x: x, y: y)
                    s.rotate(by: .radians(spin * tt))
                    s.fill(Path(CGRect(x: -w / 2, y: -w * 0.3, width: w, height: w * 0.6)), with: .color(color))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            // Pieces finish fading at about duration - 0.3 s plus up to 0.9 s of launch delay.
            try? await Task.sleep(for: .seconds(Self.duration + 1.0))
            finished = true
        }
    }
}
