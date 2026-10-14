import SwiftUI

/// The whole play screen. Layout is computed from the available size (see `GameLayout`), and every
/// element is placed in the shared "game" coordinate space the drag gesture reports in.
struct GameView: View {
    @Environment(GameViewModel.self) private var vm
    @Environment(Settings.self) private var settings

    @State private var showSettings = false
    /// Animated from n to n+1 for each board shake.
    @State private var shakePhase: CGFloat = 0
    /// True once the current touch has been matched to a tray slot (or found not to be on one).
    @State private var touchClaimed = false
    /// Flips while a finger is down; its reset tells us when a touch ended without `onEnded` (cancelled).
    @GestureState private var isTouching = false

    var body: some View {
        GeometryReader { geo in
            let layout = GameLayout(size: geo.size)

            ZStack(alignment: .topLeading) {
                HUDView(layout: layout) { showSettings = true }

                playfield(layout)

                TrayView(layout: layout)
                    .offset(x: layout.trayRect.minX, y: layout.trayRect.minY)

                if vm.phase == .noSpace {
                    NoSpaceBand(layout: layout)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                // Touch surface for the tray: the whole slot area (plus a margin), not just the pieces.
                // Gesture and hit shape are attached before `.offset`: an offset moves the hit-test region
                // along with the view only for modifiers applied inside it.
                Color.clear
                    .frame(width: layout.trayRect.width, height: layout.trayRect.height + 28)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(layout))
                    .allowsHitTesting(vm.phase == .playing)
                    .offset(x: layout.trayRect.minX, y: layout.trayRect.minY - 14)

                DragLayer(layout: layout)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(name: GameLayout.coordinateSpace)
            .animation(.easeInOut(duration: 0.25), value: vm.phase)
        }
        .background(Theme.backgroundGradient.ignoresSafeArea())
        .overlay {
            if vm.phase == .gameOver {
                GameOverView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: vm.phase)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(vm)
                .environment(settings)
                .preferredColorScheme(.dark)
        }
        .onChange(of: vm.shakeTick) {
            withAnimation(.linear(duration: 0.45)) { shakePhase += 1 }
        }
        .onChange(of: isTouching) { _, touching in
            // A cancelled touch (alert, call, system gesture) never reaches onEnded; put the piece back.
            if !touching {
                touchClaimed = false
                vm.cancelHeldPiece()
            }
        }
        .onChange(of: showSettings) { _, open in
            if open { vm.cancelHeldPiece() }
        }
    }

    // MARK: Board + effects

    private func playfield(_ layout: GameLayout) -> some View {
        ZStack {
            BoardView(layout: layout)
            EffectsLayer(layout: layout)
        }
        .frame(width: layout.boardSide, height: layout.boardSide)
        .modifier(ShakeEffect(amplitude: vm.shakeStrength, phase: shakePhase))
        .offset(x: layout.boardRect.minX, y: layout.boardRect.minY)
    }

    // MARK: Dragging

    private func dragGesture(_ layout: GameLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(GameLayout.coordinateSpace))
            .updating($isTouching) { _, state, _ in state = true }
            .onChanged { value in
                // The lift starts the instant the finger touches a slot: no long press, no minimum distance.
                if !touchClaimed {
                    touchClaimed = true
                    if let slot = layout.slotIndex(at: value.startLocation) {
                        vm.beginDrag(trayIndex: slot, finger: value.location)
                    }
                }
                guard let held = heldPiece else { return }
                vm.updateDrag(finger: value.location,
                              origin: layout.snappedOrigin(finger: value.location, shape: held.shape))
            }
            .onEnded { value in
                touchClaimed = false
                guard let held = heldPiece else { return }
                vm.endDrag(finger: value.location,
                           origin: layout.snappedOrigin(finger: value.location, shape: held.shape))
            }
    }

    /// The piece currently in the player's hand, if any.
    private var heldPiece: Piece? {
        guard vm.drag.isHolding, let index = vm.drag.trayIndex, vm.state.tray.indices.contains(index) else { return nil }
        return vm.state.tray[index]
    }
}
