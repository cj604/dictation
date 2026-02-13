import Foundation

struct AppConfig: Codable {
    var apiKey: String?
    var model: String
    var maxHistoryItems: Int
    var dictionaryPath: String
    var autoCopyOnInsertFailure: Bool
    var hotkey: String

    init(
        apiKey: String?,
        model: String,
        maxHistoryItems: Int,
        dictionaryPath: String,
        autoCopyOnInsertFailure: Bool,
        hotkey: String
    ) {
        self.apiKey = apiKey
        self.model = model
        self.maxHistoryItems = maxHistoryItems
        self.dictionaryPath = dictionaryPath
        self.autoCopyOnInsertFailure = autoCopyOnInsertFailure
        self.hotkey = hotkey
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "gpt-4o-mini-transcribe"
        maxHistoryItems = try container.decodeIfPresent(Int.self, forKey: .maxHistoryItems) ?? 20
        dictionaryPath = try container.decodeIfPresent(String.self, forKey: .dictionaryPath) ?? "~/.config/chris-dictation/voice-corrections.json"
        autoCopyOnInsertFailure = try container.decodeIfPresent(Bool.self, forKey: .autoCopyOnInsertFailure) ?? true
        hotkey = try container.decodeIfPresent(String.self, forKey: .hotkey) ?? "fn"
    }

    static let `default` = AppConfig(
        apiKey: nil,
        model: "gpt-4o-mini-transcribe",
        maxHistoryItems: 20,
        dictionaryPath: "~/.config/chris-dictation/voice-corrections.json",
        autoCopyOnInsertFailure: true,
        hotkey: "fn"
    )
}

struct HistoryItem: Codable {
    let id: UUID
    let createdAt: Date
    let model: String
    let durationSeconds: TimeInterval
    let estimatedCostUSD: Double
    let transcript: String
}

enum DictationState: Equatable {
    case idle
    case recording
    case transcribing
    case error(String)

    var statusText: String {
        switch self {
        case .idle:
            return "Idle"
        case .recording:
            return "Recording"
        case .transcribing:
            return "Transcribing"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

enum AppError: LocalizedError {
    case microphonePermissionDenied
    case recorderUnavailable
    case notRecording
    case missingAPIKey
    case invalidAudioData
    case invalidResponse
    case transcriptionFailed(String)
    case insertionFailed

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission denied."
        case .recorderUnavailable:
            return "Audio recorder unavailable."
        case .notRecording:
            return "Not currently recording."
        case .missingAPIKey:
            return "OpenAI API key missing. Set OPENAI_API_KEY or config.apiKey."
        case .invalidAudioData:
            return "Recorded audio is missing or invalid."
        case .invalidResponse:
            return "Invalid API response."
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .insertionFailed:
            return "Could not insert transcript into focused app."
        }
    }
}
