import Foundation

/// Persists finished games to a JSON file in Application Support.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var matches: [MatchRecord] = []

    private let fileURL: URL

    init(filename: String = "match-history.json") {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent(filename)
        load()
    }

    func add(_ match: MatchRecord) {
        // Online matches can be reported twice (turn event + match end); keep one.
        guard !matches.contains(where: { $0.id == match.id }) else { return }
        matches.insert(match, at: 0)
        save()
    }

    func delete(at offsets: IndexSet) {
        matches.remove(atOffsets: offsets)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([MatchRecord].self, from: data)
        else { return }
        matches = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(matches) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
