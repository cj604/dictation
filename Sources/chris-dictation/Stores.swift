import Foundation

final class ConfigStore {
    private let configURL: URL

    init(baseDirectory: URL) {
        self.configURL = baseDirectory.appendingPathComponent("config.json")
    }

    func load() -> AppConfig {
        do {
            let data = try Data(contentsOf: configURL)
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            let defaultConfig = AppConfig.default
            save(defaultConfig)
            return defaultConfig
        }
    }

    func save(_ config: AppConfig) {
        do {
            let data = try JSONEncoder.pretty.encode(config)
            try data.write(to: configURL, options: .atomic)
        } catch {
            fputs("Failed to save config: \(error)\n", stderr)
        }
    }
}

final class HistoryStore {
    private let historyURL: URL
    private let maxItemsProvider: () -> Int

    init(baseDirectory: URL, maxItemsProvider: @escaping () -> Int) {
        self.historyURL = baseDirectory.appendingPathComponent("history.json")
        self.maxItemsProvider = maxItemsProvider
    }

    func load() -> [HistoryItem] {
        do {
            let data = try Data(contentsOf: historyURL)
            return try JSONDecoder().decode([HistoryItem].self, from: data)
        } catch {
            return []
        }
    }

    func append(_ item: HistoryItem) {
        var history = load()
        history.insert(item, at: 0)
        if history.count > maxItemsProvider() {
            history = Array(history.prefix(maxItemsProvider()))
        }
        do {
            let data = try JSONEncoder.pretty.encode(history)
            try data.write(to: historyURL, options: .atomic)
        } catch {
            fputs("Failed to write history: \(error)\n", stderr)
        }
    }
}

final class DictionaryStore {
    private let fallbackURL: URL

    init(baseDirectory: URL) {
        self.fallbackURL = baseDirectory.appendingPathComponent("voice-corrections.json")
    }

    func load(path: String) -> [String: String] {
        let preferredURL = URL(fileURLWithPath: path.expandingTilde)
        if let dictionary = loadFrom(url: preferredURL) {
            return dictionary
        }

        if let dictionary = loadFrom(url: fallbackURL) {
            return dictionary
        }

        save([:], path: path)
        return [:]
    }

    func save(_ dictionary: [String: String], path: String) {
        let url = URL(fileURLWithPath: path.expandingTilde)
        let destination: URL
        if FileManager.default.fileExists(atPath: url.path) || url.path.hasPrefix(NSHomeDirectory()) {
            destination = url
        } else {
            destination = fallbackURL
        }

        do {
            let directory = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder.pretty.encode(dictionary)
            try data.write(to: destination, options: .atomic)
        } catch {
            fputs("Failed to save dictionary: \(error)\n", stderr)
        }
    }

    private func loadFrom(url: URL) -> [String: String]? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            return nil
        }
    }
}

final class TranscriptLog {
    private let logURL: URL

    init(baseDirectory: URL) {
        self.logURL = baseDirectory.appendingPathComponent("transcript-log.md")
    }

    var url: URL { logURL }

    func append(_ transcript: String) {
        let now = Date()
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd (EEEE)"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"

        let dayHeader = "## \(dayFormatter.string(from: now))"
        let timeStamp = timeFormatter.string(from: now)
        let entry = "- **\(timeStamp):** \(transcript.trimmingCharacters(in: .whitespacesAndNewlines))\n"

        do {
            if FileManager.default.fileExists(atPath: logURL.path) {
                let existing = try String(contentsOf: logURL, encoding: .utf8)
                // Check if today's header already exists
                if existing.contains(dayHeader) {
                    // Append entry under the existing day header
                    let updated = existing + entry
                    try updated.write(to: logURL, atomically: true, encoding: .utf8)
                } else {
                    // Add new day header
                    let updated = existing + "\n\(dayHeader)\n\n\(entry)"
                    try updated.write(to: logURL, atomically: true, encoding: .utf8)
                }
            } else {
                // Create file with title and first entry
                let content = "# Dictation Log\n\n\(dayHeader)\n\n\(entry)"
                try content.write(to: logURL, atomically: true, encoding: .utf8)
            }
        } catch {
            fputs("Failed to write transcript log: \(error)\n", stderr)
        }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension String {
    var expandingTilde: String {
        NSString(string: self).expandingTildeInPath
    }
}
