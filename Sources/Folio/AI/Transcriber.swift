import AVFoundation
import Foundation
import Speech
import FolioCore

/// Transcribes audio files on the Mac. Nothing is uploaded: macOS 26 uses SpeechAnalyzer (the speech
/// model is downloaded once by macOS), older systems use the on-device SFSpeechRecognizer.
@MainActor
enum Transcriber {
    enum TranscriptionError: LocalizedError {
        case unsupportedLanguage(String)
        case notAuthorized
        case unavailable(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .unsupportedLanguage(let l): return "Für „\(l)“ gibt es auf diesem Mac keine lokale Spracherkennung."
            case .notAuthorized: return "Folio darf die Spracherkennung nicht verwenden. Erlaube es in Systemeinstellungen › Datenschutz & Sicherheit › Spracherkennung."
            case .unavailable(let m): return "Die Spracherkennung ist nicht verfügbar: \(m)"
            case .empty: return "In der Aufnahme wurde keine Sprache erkannt."
            }
        }
    }

    /// Languages offered in the audio block's menu (the system language first).
    static var languages: [Locale] {
        let ids = ["de-DE", "en-US", "en-GB", "fr-FR", "es-ES", "it-IT", "nl-NL", "pt-BR", "ja-JP", "zh-CN"]
        var list = [Locale.current]
        for id in ids where !list.contains(where: { $0.identifier(.bcp47) == id }) { list.append(Locale(identifier: id)) }
        return list
    }

    static func name(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// Transcribes `url`; `status` receives short progress messages for the block.
    static func transcribe(_ url: URL, locale: Locale, status: @escaping (String) -> Void) async throws -> String {
        if #available(macOS 26.0, *) {
            return try await transcribeWithAnalyzer(url, locale: locale, status: status)
        }
        return try await transcribeWithRecognizer(url, locale: locale, status: status)
    }

    @available(macOS 26.0, *)
    private static func transcribeWithAnalyzer(_ url: URL, locale: Locale, status: @escaping (String) -> Void) async throws -> String {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unsupportedLanguage(name(of: locale))
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            status("Lade das Sprachmodell für \(name(of: supported)) …")
            try await request.downloadAndInstall()
        }
        status("Transkribiere …")
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw AudioAnalysis.AudioError.unreadable(error.localizedDescription) }
        let collector = Task { () -> [(text: String, start: TimeInterval?, end: TimeInterval?)] in
            var segments: [(text: String, start: TimeInterval?, end: TimeInterval?)] = []
            for try await result in transcriber.results where result.isFinal {
                let range = result.range
                segments.append((String(result.text.characters), range.start.seconds, range.end.seconds))
            }
            return segments
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw TranscriptionError.unavailable(error.localizedDescription)
        }
        let text = TranscriptFormatter.join(try await collector.value)
        guard !text.isEmpty else { throw TranscriptionError.empty }
        return text
    }

    private static func transcribeWithRecognizer(_ url: URL, locale: Locale, status: @escaping (String) -> Void) async throws -> String {
        let auth = await withCheckedContinuation { cont in SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) } }
        guard auth == .authorized else { throw TranscriptionError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.unsupportedLanguage(name(of: locale))
        }
        status("Transkribiere …")
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let text: String = try await withCheckedThrowingContinuation { cont in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    cont.resume(throwing: TranscriptionError.unavailable(error.localizedDescription))
                } else if let result, result.isFinal {
                    finished = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranscriptionError.empty }
        return text
    }
}
