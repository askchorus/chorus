import AVFoundation
import Foundation

/// Speaks looked-up words. For English, tries Free Dictionary API
/// (https://api.dictionaryapi.dev) first — it returns audio URLs hosted on Wikimedia
/// Commons, which are **real human recordings**. Falls back to macOS TTS when:
///   • the word isn't English (CJK / others)
///   • the API has no audio for that word
///   • the network call fails
///
/// No API key required. In-memory cache so repeated lookups are instant.
@MainActor
final class WordSpeaker {
    static let shared = WordSpeaker()

    private let synth = AVSpeechSynthesizer()
    private var player: AVPlayer?
    private var lastPlayTask: Task<Void, Never>?

    private init() {}

    // MARK: Public API

    /// Play pronunciation of `text`. Cancels any in-progress audio first.
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lastPlayTask?.cancel()
        synth.stopSpeaking(at: .immediate)
        player?.pause()

        lastPlayTask = Task { [weak self] in
            guard let self = self else { return }
            if self.isLikelyEnglish(trimmed),
               let url = await self.fetchAudioURL(for: trimmed.lowercased()) {
                self.playRemote(url)
            } else {
                self.synthSpeak(trimmed)
            }
        }
    }

    /// Warm the cache for `text` — call after a dictionary hit so the button is instant.
    /// Idempotent: returns immediately if already cached.
    func prefetchAudio(for text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isLikelyEnglish(trimmed) else { return }
        _ = await fetchAudioURL(for: trimmed)
    }

    // MARK: API lookup — delegate to OnlineDictionary's shared cache

    private func fetchAudioURL(for word: String) async -> URL? {
        await OnlineDictionary.shared.lookup(word)?.audioURL
    }

    // MARK: Playback

    private func playRemote(_ url: URL) {
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player?.play()
    }

    // MARK: TTS fallback

    private func synthSpeak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = preferredVoice(for: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        synth.speak(utterance)
    }

    private func preferredVoice(for text: String) -> AVSpeechSynthesisVoice? {
        if text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
            return AVSpeechSynthesisVoice(language: "zh-CN")
                ?? AVSpeechSynthesisVoice(language: "zh-TW")
        }
        if text.unicodeScalars.contains(where: {
            (0x3040...0x309F).contains($0.value) || (0x30A0...0x30FF).contains($0.value)
        }) {
            return AVSpeechSynthesisVoice(language: "ja-JP")
        }
        if text.unicodeScalars.contains(where: { (0xAC00...0xD7AF).contains($0.value) }) {
            return AVSpeechSynthesisVoice(language: "ko-KR")
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    // MARK: Helpers

    private func isLikelyEnglish(_ s: String) -> Bool {
        s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "'") }
    }
}

