import Foundation
import AVFoundation
import Speech

/// Ensures only ONE dictation records at a time across the whole app — the main composer, the
/// quick input, and every API panel share one microphone / recognizer. `begin` stops whoever was
/// recording and makes the given dictator active; `ended` clears it (only if it's still active,
/// so a late auto-stop can't clear a newer session). Identity-based via the dictator instance.
@MainActor
final class DictationCoordinator {
    static let shared = DictationCoordinator()
    private weak var active: SpeechDictator?

    func begin(_ d: SpeechDictator) {
        if active !== d { active?.stop() }
        active = d
    }
    func ended(_ d: SpeechDictator) {
        if active === d { active = nil }
    }
}

/// On-device voice dictation for the quick input. Uses Apple's native SFSpeechRecognizer with
/// on-device recognition when available (private, offline, free, no bundled model). Streams
/// partial results so the text box fills live as you speak. For short prompt dictation this is
/// indistinguishable in accuracy from the newer SpeechAnalyzer API, but with a far more stable
/// API and broader OS support.
///
/// Continuous dictation across pauses: SFSpeechRecognizer finalizes a segment after a pause and
/// then starts a NEW segment whose transcript begins from scratch — which would overwrite what
/// you already said. We avoid that by accumulating each finalized segment into `committedText`
/// and restarting recognition, so the box shows `committedText + current segment`.
@MainActor
final class SpeechDictator: ObservableObject {
    @Published private(set) var isRecording = false
    /// Set when permission was denied, so the UI can hint the user to enable it in System Settings.
    @Published var permissionDenied = false

    private let recognizer = SFSpeechRecognizer(locale: Locale.preferredLanguages.first.map(Locale.init) ?? Locale.current)
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onUpdate: ((String) -> Void)?
    private var committedText = ""
    /// True between start() and recording actually beginning — guards the async permission
    /// window so a rapid second tap can't spin up a second task/tap (isRecording is still false then).
    private var starting = false

    /// Auto-stop after this many seconds with no new speech (so the mic doesn't listen forever).
    private let silenceTimeout: TimeInterval = 4
    private var silenceWork: DispatchWorkItem?

    private func bumpSilenceTimer() {
        silenceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        silenceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + silenceTimeout, execute: work)
    }

    func start(onUpdate: @escaping (String) -> Void) {
        guard !isRecording, !starting else { return }
        starting = true
        self.onUpdate = onUpdate
        permissionDenied = false

        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            Task { @MainActor in
                guard let self else { return }
                guard auth == .authorized else { self.abortStart(); return }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor in
                        guard granted else { self.abortStart(); return }
                        self.beginRecording()
                    }
                }
            }
        }
    }

    /// Any failure to start (denied, recognizer unavailable, audio-engine error). Clears the
    /// starting latch AND sets permissionDenied — the published change lets the UI reset state
    /// (e.g. the quick input's suppress-auto-hide flag), which would otherwise stay stuck.
    private func abortStart() {
        starting = false
        permissionDenied = true
    }

    private func beginRecording() {
        guard let recognizer, recognizer.isAvailable else { abortStart(); return }
        committedText = ""

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        // Feed audio to whichever request is current (it gets swapped on each segment restart).
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            chorusLog.notice("[Chorus.Speech] engine start failed: \(error.localizedDescription, privacy: .public)")
            cleanup()
            abortStart()   // surface the failure so the UI resets (don't leave suppress-auto-hide stuck)
            return
        }

        starting = false
        isRecording = true
        bumpSilenceTimer()   // auto-stop if they never speak
        startSegment()
    }

    /// Start (or restart) a recognition task. Called once at begin and again after each segment
    /// is finalized, so dictation continues across pauses without losing earlier text.
    private func startSegment() {
        guard let recognizer, isRecording else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request = req

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                if let result {
                    self.bumpSilenceTimer()   // speech detected → push back the auto-stop
                    let live = result.bestTranscription.formattedString
                    self.onUpdate?(self.committedText + live)
                    if result.isFinal {
                        if !live.isEmpty { self.committedText += live + " " }
                        self.request = nil
                        self.task = nil
                        self.startSegment()   // continue listening for the next sentence
                    }
                } else if error != nil {
                    // Don't tight-loop on errors: commit what we have and stop cleanly.
                    self.stop()
                }
            }
        }
    }

    func stop() {
        guard isRecording else { cleanup(); return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        cleanup()
    }

    private func cleanup() {
        silenceWork?.cancel()
        silenceWork = nil
        request = nil
        task = nil
        isRecording = false
        starting = false
    }
}
