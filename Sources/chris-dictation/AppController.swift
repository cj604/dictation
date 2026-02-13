import AppKit
import Foundation

final class AppController: NSObject, NSApplicationDelegate {
    private var state: DictationState = .idle {
        didSet { refreshUI() }
    }

    private var statusItem: NSStatusItem!
    private var toggleRecordItem: NSMenuItem!
    private var transcribeAgainItem: NSMenuItem!
    private var copyLastItem: NSMenuItem!
    private var addCorrectionItem: NSMenuItem!
    private var stateItem: NSMenuItem!
    private var hotkeyItem: NSMenuItem!

    private let baseDirectory = URL(fileURLWithPath: NSString(string: "~/.config/chris-dictation").expandingTildeInPath)

    private lazy var configStore = ConfigStore(baseDirectory: baseDirectory)
    private var config: AppConfig!

    private lazy var historyStore = HistoryStore(baseDirectory: baseDirectory, maxItemsProvider: { [weak self] in
        self?.config.maxHistoryItems ?? 20
    })

    private lazy var dictionaryStore = DictionaryStore(baseDirectory: baseDirectory)
    private lazy var transcriptLog = TranscriptLog(baseDirectory: baseDirectory)

    private let recorder = AudioRecorderService()
    private let transcriber = OpenAITranscriptionService()
    private let corrections = DictationCorrectionService()
    private let inserter = TextInsertionService()
    private var hotkeyMonitor: HotkeyMonitor?
    private lazy var overlay = OverlayPanel(
        contentRect: .zero,
        styleMask: .borderless,
        backing: .buffered,
        defer: true
    )
    private var meterTimer: Timer?
    private var peakLevel: Float = 0

    private var lastAudioURL: URL?
    private var lastDurationSeconds: TimeInterval = 0
    private var lastTranscript: String?
    private var targetApplication: NSRunningApplication?
    private lazy var runtimeLogURL: URL = baseDirectory.appendingPathComponent("runtime.log")

    func applicationDidFinishLaunching(_ notification: Notification) {
        prepareDirectories()
        logRuntime("applicationDidFinishLaunching")
        config = configStore.load()
        setupMenuBar()
        requestAccessibilityOnce()
        setupHotkeyMonitor()
        refreshUI()
    }

    /// Prompt for Accessibility once at launch so macOS registers the current binary.
    private func requestAccessibilityOnce() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        logRuntime("accessibilityCheck trusted=\(trusted)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor?.stop()
    }

    private func prepareDirectories() {
        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        } catch {
            fputs("Failed to create app directory: \(error)\n", stderr)
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = makeWaveformIcon()
            button.toolTip = "Chris Dictation"
        }

        let menu = NSMenu()

        stateItem = NSMenuItem(title: "State: Idle", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        hotkeyItem = NSMenuItem(title: "Hotkey: hold right option to dictate", action: nil, keyEquivalent: "")
        hotkeyItem.isEnabled = false
        menu.addItem(hotkeyItem)
        menu.addItem(NSMenuItem.separator())

        toggleRecordItem = NSMenuItem(title: "Start Dictation", action: #selector(toggleRecording), keyEquivalent: "")
        toggleRecordItem.target = self
        menu.addItem(toggleRecordItem)

        transcribeAgainItem = NSMenuItem(title: "Transcribe Last Recording", action: #selector(transcribeLastRecording), keyEquivalent: "")
        transcribeAgainItem.target = self
        menu.addItem(transcribeAgainItem)

        menu.addItem(NSMenuItem.separator())

        copyLastItem = NSMenuItem(title: "Copy Last Transcript", action: #selector(copyLastTranscript), keyEquivalent: "")
        copyLastItem.target = self
        menu.addItem(copyLastItem)

        addCorrectionItem = NSMenuItem(title: "Add Dictionary Correction...", action: #selector(addCorrection), keyEquivalent: "")
        addCorrectionItem.target = self
        menu.addItem(addCorrectionItem)

        let openLog = NSMenuItem(title: "View Transcript Log", action: #selector(openTranscriptLog), keyEquivalent: "")
        openLog.target = self
        menu.addItem(openLog)

        let openHistory = NSMenuItem(title: "Open History File", action: #selector(openHistoryFile), keyEquivalent: "")
        openHistory.target = self
        menu.addItem(openHistory)

        let openConfig = NSMenuItem(title: "Open Config File", action: #selector(openConfigFile), keyEquivalent: "")
        openConfig.target = self
        menu.addItem(openConfig)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func setupHotkeyMonitor() {
        let monitor = HotkeyMonitor(
            onPress: { [weak self] in
                DispatchQueue.main.async {
                    self?.handleHotkeyPress()
                }
            },
            onRelease: { [weak self] in
                DispatchQueue.main.async {
                    self?.handleHotkeyRelease()
                }
            }
        )
        monitor.start(kind: .functionKey)
        hotkeyMonitor = monitor
        logRuntime("hotkeyMonitorStarted hotkey=fn")
    }

    private func refreshUI() {
        stateItem?.title = "State: \(state.statusText)"

        switch state {
        case .idle, .error:
            toggleRecordItem?.title = "Start Dictation"
            toggleRecordItem?.isEnabled = true
            statusItem?.button?.toolTip = "Chris Dictation"
        case .recording:
            toggleRecordItem?.title = "Stop and Insert"
            toggleRecordItem?.isEnabled = true
            statusItem?.button?.toolTip = "Chris Dictation (recording)"
        case .transcribing:
            toggleRecordItem?.title = "Transcribing..."
            toggleRecordItem?.isEnabled = false
            statusItem?.button?.toolTip = "Chris Dictation (transcribing)"
        }

        transcribeAgainItem?.isEnabled = lastAudioURL != nil
        copyLastItem?.isEnabled = !(lastTranscript?.isEmpty ?? true)
        addCorrectionItem?.isEnabled = true
    }

    private func handleHotkeyPress() {
        if case .idle = state {
            startRecording(captureCurrentApp: true)
            return
        }
        if case .error = state {
            startRecording(captureCurrentApp: true)
        }
    }

    private func handleHotkeyRelease() {
        if case .recording = state {
            stopAndTranscribeWithErrorTitle("Stop Failed")
        }
    }

    @objc private func toggleRecording() {
        switch state {
        case .idle, .error:
            startRecording(captureCurrentApp: false)
        case .recording:
            stopAndTranscribeWithErrorTitle("Stop Failed")
        case .transcribing:
            break
        }
    }

    private func startRecording(captureCurrentApp: Bool) {
        do {
            if captureCurrentApp {
                targetApplication = NSWorkspace.shared.frontmostApplication
            }
            try recorder.startRecording()
            state = .recording
            overlay.showRecording(targetApp: targetApplication)
            startMeterUpdates()
        } catch {
            state = .error(error.localizedDescription)
            showAlert(title: "Recording Failed", message: error.localizedDescription)
        }
    }

    private func startMeterUpdates() {
        peakLevel = 0
        meterTimer?.invalidate()
        meterTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let level = self.recorder.currentLevel()
            if level > self.peakLevel { self.peakLevel = level }
            self.overlay.updateLevel(CGFloat(level))
        }
        RunLoop.main.add(meterTimer!, forMode: .common)
    }

    private func stopMeterUpdates() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func stopAndTranscribeWithErrorTitle(_ title: String) {
        stopMeterUpdates()
        Task { @MainActor in
            do {
                let output = try recorder.stopRecording()
                lastAudioURL = output.url
                lastDurationSeconds = output.duration

                // Skip transcription for very short recordings or silence
                if output.duration < 0.5 || peakLevel < 0.05 {
                    overlay.dismiss()
                    state = .idle
                    return
                }

                overlay.showProcessing()
                try await transcribeCurrentAudio()
            } catch {
                overlay.dismiss()
                state = .idle
            }
        }
    }

    @objc private func transcribeLastRecording() {
        Task { @MainActor in
            do {
                try await transcribeCurrentAudio()
            } catch {
                state = .error(error.localizedDescription)
                showAlert(title: "Transcription Failed", message: error.localizedDescription)
            }
        }
    }

    private func transcribeCurrentAudio() async throws {
        guard let audioURL = lastAudioURL else {
            throw AppError.invalidAudioData
        }

        let apiKey = resolvedAPIKey()
        guard let apiKey else {
            throw AppError.missingAPIKey
        }

        state = .transcribing

        let dictionary = dictionaryStore.load(path: config.dictionaryPath)
        let prompt = corrections.whisperPrompt(dictionary: dictionary)

        let transcript = try await transcriber.transcribe(
            audioURL: audioURL,
            model: config.model,
            apiKey: apiKey,
            prompt: prompt
        )

        // Discard if Whisper just echoed back the prompt (hallucination on near-silence)
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTranscript.isEmpty || trimmedTranscript == prompt.trimmingCharacters(in: .whitespacesAndNewlines) {
            overlay.dismiss()
            state = .idle
            return
        }

        let corrected = corrections.applyCorrections(transcript, dictionary: dictionary)
        // Always add trailing space so next dictation flows naturally
        let withSpace = corrected.hasSuffix(" ") ? corrected : corrected + " "
        lastTranscript = withSpace

        let result = inserter.insert(withSpace, preferredApp: targetApplication)
        switch result {
        case .pasted:
            overlay.dismiss()
        case .clipboard:
            overlay.showCopiedToClipboard()
        }
        targetApplication = nil

        transcriptLog.append(corrected)

        historyStore.append(
            HistoryItem(
                id: UUID(),
                createdAt: Date(),
                model: config.model,
                durationSeconds: lastDurationSeconds,
                estimatedCostUSD: CostEstimator.estimateUSD(model: config.model, durationSeconds: lastDurationSeconds),
                transcript: corrected
            )
        )

        state = .idle
    }

    private func resolvedAPIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty {
            return env
        }
        if let configured = config.apiKey, !configured.isEmpty {
            return configured
        }
        return nil
    }

    @objc private func copyLastTranscript() {
        guard let transcript = lastTranscript else { return }
        inserter.copyToClipboard(transcript)
    }

    @objc private func addCorrection() {
        let wrongField = NSTextField(frame: NSRect(x: 0, y: 24, width: 280, height: 24))
        wrongField.placeholderString = "Incorrect word/phrase"

        let rightField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        rightField.placeholderString = "Correct replacement"

        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 48))
        stack.addSubview(wrongField)
        stack.addSubview(rightField)

        let alert = NSAlert()
        alert.messageText = "Add Dictionary Correction"
        alert.informativeText = "Used in prompt bias and post-transcript correction."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let wrong = wrongField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rightField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wrong.isEmpty, !right.isEmpty else {
            showAlert(title: "Invalid Correction", message: "Both fields are required.")
            return
        }

        var dictionary = dictionaryStore.load(path: config.dictionaryPath)
        dictionary[wrong] = right
        dictionaryStore.save(dictionary, path: config.dictionaryPath)
    }

    @objc private func openTranscriptLog() {
        NSWorkspace.shared.open(transcriptLog.url)
    }

    @objc private func openHistoryFile() {
        let url = baseDirectory.appendingPathComponent("history.json")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openConfigFile() {
        let url = baseDirectory.appendingPathComponent("config.json")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func quitApp() {
        recorder.cancelRecording()
        NSApplication.shared.terminate(nil)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func makeWaveformIcon() -> NSImage {
        let size = NSSize(width: 16, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let barWidth: CGFloat = 1.5
            let gap: CGFloat = 1.5
            let heights: [CGFloat] = [0.35, 0.7, 1.0, 0.55, 0.8]
            let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
            let startX = (rect.width - totalWidth) / 2
            let maxH = rect.height - 2

            NSColor.black.setFill()
            for (i, h) in heights.enumerated() {
                let x = startX + CGFloat(i) * (barWidth + gap)
                let barH = max(2, maxH * h)
                let y = (rect.height - barH) / 2
                let bar = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: barH), xRadius: 0.75, yRadius: 0.75)
                bar.fill()
            }
            return true
        }
        image.isTemplate = true // adapts to light/dark mode
        return image
    }

    private func logRuntime(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: runtimeLogURL.path) {
                if let handle = try? FileHandle(forWritingTo: runtimeLogURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: runtimeLogURL, options: .atomic)
            }
        }
    }
}
