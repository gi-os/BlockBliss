import Foundation

/// Lifetime numbers kept by the app layer. They are never given to the engine or the piece generator
/// (see GENERATOR.md: the dealer may not look at best score, history or play time).
struct Records: Codable, Equatable {
    var bestScore = 0
    var bestCombo = 0
    var gamesPlayed = 0
    var totalLines = 0
    var totalPieces = 0
    var allClears = 0
    /// Best score at the moment the current run began. A run is a "new best" when it beats this.
    var bestAtRunStart = 0
}

/// Saves the running game and the lifetime records as JSON in Application Support.
/// Everything stays on device; there is no network code anywhere in the app.
final class Persistence: @unchecked Sendable {
    static let shared = Persistence()

    private let directory: URL
    private let queue = DispatchQueue(label: "blockbliss.persistence", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var gameURL: URL { directory.appendingPathComponent("game.json") }
    private var recordsURL: URL { directory.appendingPathComponent("records.json") }

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("BlockBliss", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: Loading (synchronous, once at launch)

    /// The saved run, or nil if there is none or the file is unreadable (then a new game starts).
    func loadGame() -> GameState? {
        guard let data = try? Data(contentsOf: gameURL),
              let state = try? decoder.decode(GameState.self, from: data),
              state.tray.count == 3
        else { return nil }
        return state
    }

    func loadRecords() -> Records {
        guard let data = try? Data(contentsOf: recordsURL),
              let records = try? decoder.decode(Records.self, from: data)
        else { return Records() }
        return records
    }

    // MARK: Saving

    /// Encodes now (cheap, a couple of KB) and writes atomically on a background queue.
    func save(game state: GameState) {
        guard let data = try? encoder.encode(state) else { return }
        write(data, to: gameURL)
    }

    func save(records: Records) {
        guard let data = try? encoder.encode(records) else { return }
        write(data, to: recordsURL)
    }

    /// Blocks until every queued write has hit the disk. Called when the app is about to leave the foreground.
    func flush() {
        queue.sync {}
    }

    private func write(_ data: Data, to url: URL) {
        queue.async {
            try? data.write(to: url, options: [.atomic])
        }
    }
}
