import AppKit
import AVFoundation
import ApplicationServices
import Foundation

final class AudioRecorderService: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private(set) var currentFileURL: URL?
    private var startedAt: Date?

    func startRecording() throws {
        let permissionGranted = requestMicPermission()
        guard permissionGranted else {
            throw AppError.microphonePermissionDenied
        }

        let filename = "dictation-\(Int(Date().timeIntervalSince1970)).m4a"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        guard let recorder else {
            throw AppError.recorderUnavailable
        }

        recorder.delegate = self
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw AppError.recorderUnavailable
        }

        currentFileURL = fileURL
        startedAt = Date()
    }

    func stopRecording() throws -> (url: URL, duration: TimeInterval) {
        guard let recorder else {
            throw AppError.notRecording
        }

        recorder.stop()
        self.recorder = nil

        guard let url = currentFileURL else {
            throw AppError.invalidAudioData
        }

        let duration = max(0, Date().timeIntervalSince(startedAt ?? Date()))
        currentFileURL = nil
        startedAt = nil

        return (url, duration)
    }

    func currentLevel() -> Float {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0) // -160 to 0
        // Normalize: -40dB and below = silent, 0dB = max
        // Lower threshold = more sensitive to quiet speech
        let minDb: Float = -40
        let normalized = max(0, (db - minDb) / -minDb)
        return normalized
    }

    func cancelRecording() {
        recorder?.stop()
        recorder = nil
        if let currentFileURL {
            try? FileManager.default.removeItem(at: currentFileURL)
        }
        self.currentFileURL = nil
        self.startedAt = nil
    }

    private func requestMicPermission() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                granted = allowed
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 10)
            return granted
        default:
            return false
        }
    }
}

final class DictationCorrectionService {
    func whisperPrompt(dictionary: [String: String]) -> String {
        let names = Set(dictionary.values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !names.isEmpty else { return "" }
        return "Names and terms: \(names.sorted().joined(separator: ", "))."
    }

    func applyCorrections(_ text: String, dictionary: [String: String]) -> String {
        var result = text
        let sorted = dictionary.sorted { lhs, rhs in
            lhs.key.count > rhs.key.count
        }

        for (wrong, right) in sorted {
            if wrong.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            let pattern = patternForTerm(wrong)
            result = result.replacingOccurrences(
                of: pattern,
                with: right,
                options: [.regularExpression, .caseInsensitive]
            )
        }

        return result
    }

    private func patternForTerm(_ term: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: term)
        return "(?<!\\w)\(escaped)(?!\\w)"
    }
}

final class OpenAITranscriptionService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribe(audioURL: URL, model: String, apiKey: String, prompt: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioURL)
        guard !audioData.isEmpty else {
            throw AppError.invalidAudioData
        }

        let ext = audioURL.pathExtension.isEmpty ? "m4a" : audioURL.pathExtension
        var body = Data()

        body.appendMultipart(name: "model", value: model, boundary: boundary)
        body.appendMultipart(name: "response_format", value: "text", boundary: boundary)
        if !prompt.isEmpty {
            body.appendMultipart(name: "prompt", value: prompt, boundary: boundary)
        }
        body.appendFileMultipart(name: "file", filename: "audio.\(ext)", mimeType: "audio/\(ext)", data: audioData, boundary: boundary)
        body.append("--\(boundary)--\r\n")

        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AppError.transcriptionFailed(errorText)
        }

        guard let transcript = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !transcript.isEmpty else {
            throw AppError.invalidResponse
        }

        return transcript
    }
}

enum InsertResult {
    case pasted      // Cmd+V was simulated
    case clipboard   // Copied to clipboard only (no paste possible)
}

final class TextInsertionService {
    func insert(_ text: String, preferredApp: NSRunningApplication?) -> InsertResult {
        // Always put text on clipboard first
        copyToClipboard(text)

        if let preferredApp {
            preferredApp.activate()
            Thread.sleep(forTimeInterval: 0.2)
        }

        // Try paste if accessibility is available
        guard AXIsProcessTrusted() else {
            return .clipboard
        }

        if simulatePaste() {
            return .pasted
        }

        return .clipboard
    }

    /// Check if the currently focused UI element looks like it accepts text input.
    private func hasFocusedTextElement() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else {
            return false
        }

        let element = focused as! AXUIElement

        // Check role — text fields, text areas, combo boxes, web areas all accept text
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            let textRoles: Set<String> = [
                kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole,
                "AXWebArea", "AXSearchField",
            ]
            if textRoles.contains(role) {
                return true
            }
        }

        // Fallback: check if the element has a settable value attribute
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success {
            return settable.boolValue
        }

        return false
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func simulatePaste() -> Bool {
        guard AXIsProcessTrusted() else {
            return false
        }

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        let keyVDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyVUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyVDown?.flags = .maskCommand
        keyVUp?.flags = .maskCommand
        keyVDown?.post(tap: .cghidEventTap)
        keyVUp?.post(tap: .cghidEventTap)
        return true
    }
}

enum HotkeyKind {
    case functionKey
    case rightOption
}

final class HotkeyMonitor {
    private var flagsMonitor: Any?
    private var isFunctionPressed = false
    private var hotkeyKind: HotkeyKind = .functionKey
    private let onPress: () -> Void
    private let onRelease: () -> Void

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    func start(kind: HotkeyKind) {
        stop()
        hotkeyKind = kind
        switch kind {
        case .functionKey:
            flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
                self?.handleFlagsChanged(event)
            }
        case .rightOption:
            flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
                self?.handleFlagsChanged(event)
            }
        }
    }

    func stop() {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        isFunctionPressed = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.type == .flagsChanged else { return }
        let currentlyPressed: Bool
        switch hotkeyKind {
        case .functionKey:
            currentlyPressed = event.modifierFlags.contains(.function)
        case .rightOption:
            // Key code 61 is right option (alternate) on macOS.
            guard event.keyCode == 61 else { return }
            currentlyPressed = event.modifierFlags.contains(.option)
        }
        if currentlyPressed && !isFunctionPressed {
            isFunctionPressed = true
            onPress()
            return
        }
        if !currentlyPressed && isFunctionPressed {
            isFunctionPressed = false
            onRelease()
        }
    }
}

enum CostEstimator {
    static func estimateUSD(model: String, durationSeconds: TimeInterval) -> Double {
        let minutes = durationSeconds / 60.0
        let rate: Double
        switch model {
        case "gpt-4o-mini-transcribe":
            rate = 0.003
        case "whisper-1", "gpt-4o-transcribe":
            rate = 0.006
        default:
            rate = 0.006
        }
        return minutes * rate
    }
}

private extension Data {
    mutating func append(_ string: String) {
        self.append(string.data(using: .utf8)!)
    }

    mutating func appendMultipart(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    mutating func appendFileMultipart(name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        append(data)
        append("\r\n")
    }
}
