import SwiftUI

/// Top of the screen: crown + best (left), settings gear (right), the big score in the middle, and a
/// small pulsing chip while a combo streak is active.
struct HUDView: View {
    @Environment(GameViewModel.self) private var vm
    @Environment(Settings.self) private var settings
    let layout: GameLayout
    let openSettings: () -> Void

    private let topRowHeight: CGFloat = 44

    var body: some View {
        let state = vm.state
        let showCombo = state.combo >= 2 && !state.isGameOver
        let scoreSize = ((layout.hudHeight - topRowHeight) * 0.92).clamped(40, 66)

        VStack(spacing: 0) {
            ZStack {
                HStack {
                    bestBadge
                    Spacer(minLength: 8)
                    gearButton
                }
                if showCombo {
                    ComboChip(combo: state.combo, animated: !settings.reduceEffects)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(height: topRowHeight)
            .padding(.horizontal, 16)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showCombo)

            ScoreView(score: state.score, fontSize: scoreSize, reduce: settings.reduceEffects)
                .frame(maxHeight: .infinity)
        }
        .frame(width: layout.size.width, height: layout.hudHeight)
    }

    private var bestBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "crown.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.crown)
            Text("\(vm.bestScore)")
                .font(Theme.rounded(24))
                .foregroundStyle(Theme.bestScore)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .shadow(color: .black.opacity(0.35), radius: 0, x: 0, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Best score")
        .accessibilityValue("\(vm.bestScore)")
    }

    private var gearButton: some View {
        Button {
            SoundEngine.shared.play(.tap)
            Haptics.shared.tap()
            openSettings()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.gear)
                .shadow(color: .black.opacity(0.3), radius: 0, x: 0, y: 2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .accessibilityHint("Opens sound, vibration, fair play and stats")
    }
}

// MARK: - Score

/// The big score. When points are gained it counts up over about 0.6 to 1 s.
struct ScoreView: View {
    let score: Int
    let fontSize: CGFloat
    let reduce: Bool

    @State private var shown: Double

    init(score: Int, fontSize: CGFloat, reduce: Bool) {
        self.score = score
        self.fontSize = fontSize
        self.reduce = reduce
        _shown = State(initialValue: Double(score))
    }

    var body: some View {
        CountingText(value: shown, size: fontSize)
            .onChange(of: score) { old, new in
                if new < old {
                    // A new game: snap straight to the new value.
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { shown = Double(new) }
                } else {
                    let duration = reduce ? 0.2 : min(1.0, 0.6 + Double(new - old) / 800)
                    withAnimation(.easeOut(duration: duration)) { shown = Double(new) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Score")
            .accessibilityValue("\(score)")
    }
}

/// Text whose number is interpolated by SwiftUI's animation system, giving a smooth count-up.
private struct CountingText: View, Animatable {
    var value: Double
    let size: CGFloat

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text("\(Int(value.rounded()))")
            .font(Theme.rounded(size))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .shadow(color: .black.opacity(0.35), radius: 0, x: 0, y: 3)
            .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 4)
    }
}

// MARK: - Combo chip

/// Small "Combo N" pill that gently pulses while a streak (2 or more) is alive.
struct ComboChip: View {
    let combo: Int
    let animated: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Text("Combo")
                .font(Theme.rounded(14))
            Text("\(combo)")
                .font(Theme.rounded(18))
                .foregroundStyle(Theme.bestScore)
        }
        .italic()
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(LinearGradient(colors: [Color(hex: 0xFF8A3D), Color(hex: 0xE5503A)], startPoint: .top, endPoint: .bottom))
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.25), radius: 0, x: 0, y: 2)
        .scaleEffect(animated && pulse ? 1.07 : 1)
        .animation(animated ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : nil, value: pulse)
        .onAppear { pulse = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Combo streak")
        .accessibilityValue("\(combo)")
    }
}
