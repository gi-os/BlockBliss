import AVFoundation
import UIKit

// MARK: - Public API

/// Every sound the game can make.
enum SoundEffect: Hashable, Sendable {
    /// Lifting a piece out of the tray.
    case pickup
    /// A valid drop on the board.
    case place
    /// A drop on an invalid spot (the piece springs back).
    case invalid
    /// A line clear. `lines` is rows + columns cleared by the move (1...6); `combo` is the streak level
    /// (0 = none). Out-of-range values are clamped to the pre-rendered table (combo 9 = "9 or more").
    case clear(lines: Int, combo: Int)
    /// The board was emptied.
    case allClear
    /// A new personal best was set.
    case newBest
    /// No piece fits any more.
    case gameOver
    /// A UI button press.
    case tap
}

/// Plays the game's sounds, which are all synthesised in code (no asset files).
///
/// Design notes:
/// - Audio runs through one `AVAudioEngine` and a small pool of `AVAudioPlayerNode`s, so sounds can overlap.
/// - The audio session is `.ambient` + `.mixWithOthers`: it follows the silent switch and never interrupts
///   the player's own music.
/// - Sounds are rendered once into `AVAudioPCMBuffer`s on a background task shortly after launch, so `play`
///   only schedules a ready buffer. If a sound is requested before its buffer is ready, that one buffer is
///   rendered on the spot (a few milliseconds at most).
/// - Interruptions, route changes, configuration changes and media-service resets are handled by rebuilding
///   or restarting the engine. If the engine can't start, the game just stays silent.
/// - While disabled the engine is stopped and `play` returns immediately. While enabled but idle for a
///   while, the engine is paused so the audio hardware isn't kept busy rendering silence.
@MainActor
final class SoundEngine {
    static let shared = SoundEngine()

    /// Persisted by the app's settings. Turning it off silences everything and stops the engine.
    var isEnabled: Bool = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { prepare() } else { shutDown() }
        }
    }

    // MARK: State

    private let format = AVAudioFormat(standardFormatWithSampleRate: SoundSynth.sampleRate, channels: 1)
    private var engine: AVAudioEngine?
    private var players: [AVAudioPlayerNode] = []
    /// Per player: the time (system uptime) at which its current buffer finishes.
    private var busyUntil: [TimeInterval] = []
    private var buffers: [SoundKey: AVAudioPCMBuffer] = [:]

    private var prewarmStarted = false
    private var interrupted = false
    private var nextStartAttempt: TimeInterval = 0
    private var lastPlay: TimeInterval = 0
    private var idleMonitor: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private let poolSize = 6
    /// Pause the engine after this long without a sound.
    private let idleTimeout: TimeInterval = 30

    private init() {
        registerObservers()
        // Deferred one tick so the app can set `isEnabled` from its settings first; a disabled engine
        // never renders or starts anything.
        Task { @MainActor [weak self] in self?.prepare() }
    }

    // MARK: Playback

    func play(_ effect: SoundEffect) {
        guard isEnabled else { return }
        guard let buffer = buffer(for: SoundKey(effect)), ensureRunning(), let format else { return }

        let now = ProcessInfo.processInfo.systemUptime
        lastPlay = now

        // Use the player that frees up soonest (an idle one if any). If every player is busy, the chosen
        // one is cut off by `.interrupts`; all buffers end in a short fade so that doesn't click.
        guard let index = busyUntil.indices.min(by: { busyUntil[$0] < busyUntil[$1] }) else { return }
        let node = players[index]
        busyUntil[index] = now + Double(buffer.frameLength) / format.sampleRate

        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !node.isPlaying, engine?.isRunning == true { node.play() }
    }

    /// Optional warm-up: renders the sound table in the background and starts the engine so the first
    /// sound has no start-up delay. Called automatically shortly after launch and when sound is re-enabled.
    func prepare() {
        guard isEnabled else { return }
        prewarmBuffers()
        _ = ensureRunning()
    }

    // MARK: Buffers

    private func prewarmBuffers() {
        guard !prewarmStarted else { return }
        prewarmStarted = true
        Task.detached(priority: .utility) { [weak self] in
            let rendered = SoundSynth.renderAll()
            await self?.install(rendered)
        }
    }

    private func install(_ rendered: [SoundKey: [Float]]) {
        for (key, samples) in rendered where buffers[key] == nil {
            buffers[key] = makeBuffer(samples)
        }
    }

    private func buffer(for key: SoundKey) -> AVAudioPCMBuffer? {
        if let cached = buffers[key] { return cached }
        let buffer = makeBuffer(SoundSynth.render(key))
        buffers[key] = buffer
        return buffer
    }

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }

    // MARK: Engine lifecycle

    /// Makes sure the engine is running, (re)building and starting it if necessary. Cheap when it already
    /// is running. After a failure it backs off for a second so a broken audio route costs nothing.
    @discardableResult
    private func ensureRunning() -> Bool {
        if let engine, engine.isRunning, !players.isEmpty { return true }
        guard !interrupted else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextStartAttempt else { return false }

        configureSession()
        if engine == nil { buildGraph() }
        guard let engine else { nextStartAttempt = now + 1; return false }

        do {
            try engine.start()
        } catch {
            // Most likely a stale graph (route change, media-services reset): rebuild on the next attempt.
            tearDownGraph()
            nextStartAttempt = now + 1
            return false
        }
        // Players may have lost their state across a pause or restart; start them all so scheduling a
        // buffer plays immediately.
        for node in players {
            node.stop()
            node.play()
        }
        startIdleMonitor()
        return true
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // Not fatal: the engine may still start, and if not `ensureRunning` backs off.
        }
    }

    private func buildGraph() {
        guard let format else { return }
        tearDownGraph()
        let engine = AVAudioEngine()
        var nodes: [AVAudioPlayerNode] = []
        for _ in 0..<poolSize {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            nodes.append(node)
        }
        // Headroom: the three loudest sounds (place + clear + all clear) can overlap, and their peaks
        // (0.40 + 0.42 + 0.42) must still sum to less than full scale.
        engine.mainMixerNode.outputVolume = 0.75
        engine.prepare()
        self.engine = engine
        players = nodes
        busyUntil = Array(repeating: 0, count: nodes.count)
    }

    private func tearDownGraph() {
        idleMonitor?.cancel()
        idleMonitor = nil
        for node in players { node.stop() }
        engine?.stop()
        engine = nil
        players = []
        busyUntil = []
    }

    /// Stops all audio work (sound turned off).
    private func shutDown() {
        idleMonitor?.cancel()
        idleMonitor = nil
        for node in players { node.stop() }
        engine?.pause()
        busyUntil = Array(repeating: 0, count: players.count)
    }

    /// Pauses the engine once nothing has played for `idleTimeout`; the next `play` restarts it.
    private func startIdleMonitor() {
        idleMonitor?.cancel()
        idleMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                if ProcessInfo.processInfo.systemUptime - self.lastPlay > self.idleTimeout {
                    self.engine?.pause()
                    self.idleMonitor = nil
                    return
                }
            }
        }
    }

    // MARK: System notifications

    private func registerObservers() {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor @Sendable (Notification) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { handler(note) }
            }
            observers.append(token)
        }

        // The audio hardware changed (route, sample rate...). The engine has already stopped itself.
        observe(.AVAudioEngineConfigurationChange) { [weak self] note in
            guard let self, let engine = self.engine, note.object as AnyObject? === engine else { return }
            self.restartAfterSystemChange()
        }
        // Calls, Siri, alarms...
        observe(AVAudioSession.interruptionNotification) { [weak self] note in
            guard let self else { return }
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            switch raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) {
            case .began:
                self.interrupted = true
                self.engine?.pause()
            case .ended:
                self.interrupted = false
                self.restartAfterSystemChange()
            default:
                break
            }
        }
        // Headphones plugged/unplugged, Bluetooth connected...
        observe(AVAudioSession.routeChangeNotification) { [weak self] _ in
            guard let self, self.isEnabled else { return }
            _ = self.ensureRunning()
        }
        // The audio daemon crashed: every audio object is invalid and must be recreated.
        observe(AVAudioSession.mediaServicesWereResetNotification) { [weak self] _ in
            self?.restartAfterSystemChange()
        }
        observe(UIApplication.didEnterBackgroundNotification) { [weak self] _ in
            self?.engine?.pause()
            self?.idleMonitor?.cancel()
            self?.idleMonitor = nil
        }
        observe(UIApplication.didBecomeActiveNotification) { [weak self] _ in
            guard let self else { return }
            self.interrupted = false
            if self.isEnabled { _ = self.ensureRunning() }
        }
    }

    /// Discards the graph and, if sound is on, builds and starts a fresh one.
    private func restartAfterSystemChange() {
        tearDownGraph()
        nextStartAttempt = 0
        if isEnabled { _ = ensureRunning() }
    }
}

// MARK: - Synthesis

/// Identifies one pre-rendered buffer. Clear variants are clamped: lines 1...6, combo 0...9.
private nonisolated enum SoundKey: Hashable, Sendable {
    case pickup, place, invalid, tap, allClear, newBest, gameOver
    case clear(lines: Int, combo: Int)

    static let maxLines = 6
    static let maxCombo = 9

    init(_ effect: SoundEffect) {
        switch effect {
        case .pickup: self = .pickup
        case .place: self = .place
        case .invalid: self = .invalid
        case .tap: self = .tap
        case .allClear: self = .allClear
        case .newBest: self = .newBest
        case .gameOver: self = .gameOver
        case let .clear(lines, combo):
            self = .clear(lines: min(max(lines, 1), Self.maxLines), combo: min(max(combo, 0), Self.maxCombo))
        }
    }

    /// Every buffer the engine can ask for.
    static var all: [SoundKey] {
        var keys: [SoundKey] = [.pickup, .place, .invalid, .tap, .allClear, .newBest, .gameOver]
        for lines in 1...maxLines {
            for combo in 0...maxCombo { keys.append(.clear(lines: lines, combo: combo)) }
        }
        return keys
    }
}

/// Additive synthesis of soft, toy-like sounds: a few sine partials per note with a fast (raised-cosine)
/// attack and an exponential decay, mixed, faded out and peak-normalised. Pure functions, no shared state,
/// so everything can run on a background thread.
private nonisolated enum SoundSynth {
    static let sampleRate = 44_100.0

    /// One sine component of a note, relative to the note's frequency and level.
    struct Partial {
        var ratio: Double
        var gain: Double
        /// Multiplies the note's decay time constant (upper partials die faster, which keeps the tone soft).
        var decayScale = 1.0
    }

    struct Note {
        var frequency: Double
        /// Offset from the start of the sound, in seconds.
        var start = 0.0
        var attack = 0.004
        /// Time constant of the exponential decay of the fundamental, in seconds.
        var decay: Double
        var gain = 1.0
        /// Optional pitch glide: the note starts at `frequency * glideFrom` and settles to `frequency`
        /// with time constant `glideTime`.
        var glideFrom: Double?
        var glideTime = 0.02
        var partials: [Partial]
        /// Hard limit on how long the note is rendered (the master fade-out hides the cut).
        var maxLength = 1.0
    }

    // MARK: Rendering core

    /// The note is rendered until it has decayed by ~60 dB, or `maxLength`.
    private static func length(of note: Note) -> Double {
        let slowest = note.partials.map(\.decayScale).max() ?? 1
        return min(note.maxLength, note.decay * slowest * 7)
    }

    /// Mixes notes into one buffer, fades the end to silence and scales so the loudest sample is `peak`.
    static func mix(_ notes: [Note], peak: Double, fadeOut: Double = 0.02) -> [Float] {
        let sr = sampleRate
        let total = notes.map { $0.start + length(of: $0) }.max() ?? 0
        let frames = Int(((total + 0.004) * sr).rounded(.up))
        var out = [Double](repeating: 0, count: frames)
        for note in notes { add(note, to: &out) }

        // Raised-cosine fade to exactly zero at the end, so a note cut at `maxLength` never clicks.
        let fadeFrames = min(Int(fadeOut * sr), frames / 2)
        for i in 0..<fadeFrames {
            let x = Double(i) / Double(fadeFrames)
            out[frames - fadeFrames + i] *= 0.5 + 0.5 * cos(.pi * x)
        }
        if fadeFrames > 0 { out[frames - 1] = 0 }

        let loudest = out.reduce(0) { max($0, abs($1)) }
        let scale = loudest > 0 ? peak / loudest : 0
        return out.map { Float($0 * scale) }
    }

    private static func add(_ note: Note, to out: inout [Double]) {
        let sr = sampleRate
        let startFrame = Int((note.start * sr).rounded())
        let count = min(Int((length(of: note) * sr).rounded()), out.count - startFrame)
        guard count > 0 else { return }
        let attackFrames = max(1, Int(note.attack * sr))

        for partial in note.partials {
            let base = note.frequency * partial.ratio
            guard base * (note.glideFrom ?? 1) < 16_000 else { continue }   // inaudible, and avoids aliasing
            var env = note.gain * partial.gain
            let decayStep = exp(-1.0 / (note.decay * partial.decayScale * sr))

            if let glideFrom = note.glideFrom {
                // Time-varying pitch: accumulate phase explicitly.
                var phase = 0.0
                var bend = glideFrom - 1            // decays to 0
                let bendStep = exp(-1.0 / (note.glideTime * sr))
                for i in 0..<count {
                    out[startFrame + i] += env * attack(i, attackFrames) * sin(phase)
                    phase += 2 * .pi * base * (1 + bend) / sr
                    bend *= bendStep
                    env *= decayStep
                }
            } else {
                // Fixed pitch: a rotating phasor is much cheaper than calling sin() per sample.
                let w = 2 * Double.pi * base / sr
                let (cw, sw) = (cos(w), sin(w))
                var (s, c) = (0.0, 1.0)
                for i in 0..<count {
                    out[startFrame + i] += env * attack(i, attackFrames) * s
                    (s, c) = (s * cw + c * sw, c * cw - s * sw)
                    env *= decayStep
                }
            }
        }
    }

    /// Smooth (sin²) fade-in gain for frame `i`.
    @inline(__always)
    private static func attack(_ i: Int, _ frames: Int) -> Double {
        guard i < frames else { return 1 }
        let s = sin(Double.pi / 2 * Double(i) / Double(frames))
        return s * s
    }

    // MARK: Pitch helpers

    private static func hz(midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }

    private static let pentatonic = [0, 2, 4, 7, 9]          // major pentatonic: C D E G A
    private static let rootMIDI = 72                          // C5

    /// Frequency of step `index` of the major pentatonic scale starting at C5 (5 steps per octave).
    /// Every pair of pentatonic notes is consonant, so overlapping notes never clash.
    private static func pentatonicHz(_ index: Int) -> Double {
        let octave = index / 5, step = index % 5
        return hz(midi: Double(rootMIDI + 12 * octave + pentatonic[step]))
    }

    /// Folds a frequency down by octaves until it is comfortably below the harsh range.
    private static func foldedBelow(_ limit: Double, _ f: Double) -> Double {
        var f = f
        while f > limit { f /= 2 }
        return f
    }

    // MARK: Sound table

    static func renderAll() -> [SoundKey: [Float]] {
        var table: [SoundKey: [Float]] = [:]
        for key in SoundKey.all { table[key] = render(key) }
        return table
    }

    static func render(_ key: SoundKey) -> [Float] {
        switch key {
        case .pickup: return pickup()
        case .place: return place()
        case .invalid: return invalid()
        case .tap: return tap()
        case .allClear: return allClear()
        case .newBest: return newBest()
        case .gameOver: return gameOver()
        case let .clear(lines, combo): return clear(lines: lines, combo: combo)
        }
    }

    /// Tiny soft blip that lifts in pitch. ~70 ms.
    private static func pickup() -> [Float] {
        mix([Note(frequency: 1250, attack: 0.002, decay: 0.014, glideFrom: 0.8, glideTime: 0.012,
                  partials: [Partial(ratio: 1, gain: 1), Partial(ratio: 2, gain: 0.18, decayScale: 0.6)],
                  maxLength: 0.07)],
            peak: 0.30)
    }

    /// Wooden/glassy "plink": a G5 with a quick pitch settle, inharmonic upper partials (like a small
    /// bar or glass) and a soft low knock underneath. ~110 ms.
    private static func place() -> [Float] {
        mix([
            Note(frequency: 784, attack: 0.001, decay: 0.022, glideFrom: 1.25, glideTime: 0.012,
                 partials: [Partial(ratio: 1, gain: 1),
                            Partial(ratio: 2.76, gain: 0.34, decayScale: 0.45),
                            Partial(ratio: 5.40, gain: 0.10, decayScale: 0.25)],
                 maxLength: 0.11),
            Note(frequency: 196, attack: 0.002, decay: 0.03, gain: 0.45,
                 partials: [Partial(ratio: 1, gain: 1)], maxLength: 0.1),
        ], peak: 0.40)
    }

    /// Soft muted thud: a low tone sagging in pitch with no bright partials. ~200 ms.
    private static func invalid() -> [Float] {
        mix([Note(frequency: 120, attack: 0.004, decay: 0.05, glideFrom: 1.7, glideTime: 0.045,
                  partials: [Partial(ratio: 1, gain: 1),
                             Partial(ratio: 2, gain: 0.30, decayScale: 0.5),
                             Partial(ratio: 3, gain: 0.08, decayScale: 0.3)],
                  maxLength: 0.2)],
            peak: 0.42)
    }

    /// UI click. ~50 ms.
    private static func tap() -> [Float] {
        mix([Note(frequency: 1400, attack: 0.0015, decay: 0.009,
                  partials: [Partial(ratio: 1, gain: 1), Partial(ratio: 2.4, gain: 0.25, decayScale: 0.5)],
                  maxLength: 0.05)],
            peak: 0.26)
    }

    /// A bell-like chime note: octave and twelfth partials that die quickly, optionally with a slightly
    /// detuned twin that makes it shimmer.
    private static func chime(_ f: Double, start: Double, decay: Double, gain: Double,
                              richness: Double, shimmer: Bool, maxLength: Double) -> Note {
        var partials = [
            Partial(ratio: 1, gain: 1),
            Partial(ratio: 2, gain: 0.28 + 0.12 * richness, decayScale: 0.55),
            Partial(ratio: 3, gain: 0.08 + 0.06 * richness, decayScale: 0.35),
        ]
        if shimmer { partials.append(Partial(ratio: 1.0028, gain: 0.55)) }   // +5 cents -> slow beating
        return Note(frequency: f, start: start, attack: 0.003, decay: decay, gain: gain,
                    partials: partials, maxLength: maxLength)
    }

    /// Line-clear chime.
    /// - The phrase's anchor pitch climbs the pentatonic scale with `combo` (C5 ... A6).
    /// - One line is a single chime. More lines add notes in a quick rising arpeggio (C-E-G-C-E-G over
    ///   the anchor), and the phrase gets richer: more upper partials, shimmer from 4 lines, a low body
    ///   note from 4 and a high sparkle at 6.
    /// Up to ~580 ms.
    private static func clear(lines: Int, combo: Int) -> [Float] {
        let n = min(max(lines, 1), SoundKey.maxLines)
        let anchor = min(max(combo, 0), SoundKey.maxCombo)
        let richness = Double(n - 1) / Double(SoundKey.maxLines - 1)
        let offsets = [0, 2, 3, 5, 7, 8]
        let spacing = n <= 2 ? 0.045 : 0.036
        let limit = 0.58

        var notes: [Note] = []
        for k in 0..<n {
            let f = foldedBelow(2800, pentatonicHz(anchor + offsets[k]))
            let progress = n > 1 ? Double(k) / Double(n - 1) : 1
            let tilt = min(1, pow(900 / f, 0.4))                 // ear is more sensitive up high
            let start = Double(k) * spacing
            notes.append(chime(f, start: start, decay: k < n - 1 ? 0.08 : (n == 1 ? 0.075 : 0.09),
                               gain: tilt * (0.75 + 0.25 * progress), richness: richness,
                               shimmer: n >= 4, maxLength: limit - start))
        }
        if n >= 4 {
            let body = foldedBelow(2800, pentatonicHz(anchor)) / 2
            notes.append(Note(frequency: body, attack: 0.006, decay: 0.1, gain: 0.3 * richness,
                              partials: [Partial(ratio: 1, gain: 1)], maxLength: limit))
        }
        if n == SoundKey.maxLines {
            // High sparkle an octave above the final arpeggio note (skipped if it would be shrill).
            let top = foldedBelow(2800, pentatonicHz(anchor + offsets[n - 1])) * 2
            let start = Double(n - 1) * spacing + 0.02
            if top < 3600 {
                notes.append(Note(frequency: top, start: start, attack: 0.002, decay: 0.05, gain: 0.22,
                                  partials: [Partial(ratio: 1, gain: 1)], maxLength: limit - start))
            }
        }
        return mix(notes, peak: 0.42)
    }

    /// All Clear: a fast ascending pentatonic run with shimmer, twinkles on top and a bloom chord at the
    /// end. ~580 ms.
    private static func allClear() -> [Float] {
        let limit = 0.58
        var notes: [Note] = []
        for k in 0..<8 {                                           // C5 D5 E5 G5 A5 C6 D6 E6
            let start = Double(k) * 0.042
            notes.append(chime(pentatonicHz(k), start: start, decay: 0.07, gain: 0.7 + 0.04 * Double(k),
                               richness: 0.6, shimmer: true, maxLength: limit - start))
        }
        for idx in [5, 7, 8] {                                     // C6 E6 G6 bloom
            notes.append(chime(pentatonicHz(idx), start: 0.34, decay: 0.075, gain: 0.8,
                               richness: 0.8, shimmer: true, maxLength: limit - 0.34))
        }
        // Twinkles: fixed times and pitches so the sound is the same every time.
        let twinkles: [(Double, Int)] = [(0.06, 10), (0.11, 12), (0.17, 9), (0.22, 11),
                                         (0.27, 12), (0.31, 10), (0.36, 11), (0.41, 12)]
        for (start, idx) in twinkles {
            notes.append(Note(frequency: pentatonicHz(idx), start: start, attack: 0.002, decay: 0.035, gain: 0.22,
                              partials: [Partial(ratio: 1, gain: 1)], maxLength: limit - start))
        }
        return mix(notes, peak: 0.42)
    }

    /// New best: a short, soft four-note fanfare (C5 E5 G5 C6) on triangle-like notes, ending on a held
    /// chord. ~580 ms.
    private static func newBest() -> [Float] {
        let limit = 0.58
        let midi = [72.0, 76.0, 79.0, 84.0]
        // Odd harmonics at 1/n² give a triangle wave: soft, a little hollow.
        let triangle = [Partial(ratio: 1, gain: 1),
                        Partial(ratio: 3, gain: 0.11, decayScale: 0.6),
                        Partial(ratio: 5, gain: 0.04, decayScale: 0.4),
                        Partial(ratio: 1.0028, gain: 0.5)]
        var notes: [Note] = []
        for (k, m) in midi.enumerated() {
            let start = Double(k) * 0.1
            notes.append(Note(frequency: hz(midi: m), start: start, attack: 0.006,
                              decay: k == 3 ? 0.15 : 0.09, gain: 0.8 + 0.07 * Double(k),
                              partials: triangle, maxLength: limit - start))
        }
        notes.append(Note(frequency: hz(midi: 79), start: 0.3, attack: 0.006, decay: 0.15, gain: 0.5,
                          partials: triangle, maxLength: limit - 0.3))
        notes.append(Note(frequency: hz(midi: 72), start: 0.3, attack: 0.008, decay: 0.15, gain: 0.4,
                          partials: [Partial(ratio: 1, gain: 1)], maxLength: limit - 0.3))
        return mix(notes, peak: 0.38)
    }

    /// Game over: a gentle descending D-minor phrase (A4 F4 D4) on soft sines. Sad but not punishing. ~600 ms.
    private static func gameOver() -> [Float] {
        let limit = 0.59
        let midi = [69.0, 65.0, 62.0]
        let soft = [Partial(ratio: 1, gain: 1),
                    Partial(ratio: 2, gain: 0.2, decayScale: 0.5),
                    Partial(ratio: 3, gain: 0.05, decayScale: 0.3)]
        var notes: [Note] = []
        for (k, m) in midi.enumerated() {
            let start = Double(k) * 0.13
            notes.append(Note(frequency: hz(midi: m), start: start, attack: 0.008,
                              decay: k == 2 ? 0.1 : 0.08, gain: 1 - 0.07 * Double(k),
                              partials: soft, maxLength: limit - start))
        }
        return mix(notes, peak: 0.34)
    }
}
