import AVFoundation
import AppKit
import SwiftUI
import FolioCore

/// Records from the microphone into an AAC file and reports the level for a live waveform.
@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var levels: [Float] = []
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var fileURL: URL?

    enum RecordError: LocalizedError {
        case denied, failed(String)
        var errorDescription: String? {
            switch self {
            case .denied: return "Folio hat keinen Zugriff auf das Mikrofon. Erlaube ihn in Systemeinstellungen › Datenschutz & Sicherheit › Mikrofon."
            case .failed(let m): return "Die Aufnahme konnte nicht starten: \(m)"
            }
        }
    }

    func start() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RecordError.denied }
        default: throw RecordError.denied
        }
        guard AVCaptureDevice.default(for: .audio) != nil else { throw RecordError.failed("Kein Mikrofon gefunden.") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Folio-Aufnahme-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let r: AVAudioRecorder
        do { r = try AVAudioRecorder(url: url, settings: settings) } catch { throw RecordError.failed(error.localizedDescription) }
        r.isMeteringEnabled = true
        guard r.record() else { throw RecordError.failed("Das Mikrofon hat nicht reagiert.") }
        recorder = r
        fileURL = url
        levels = []
        elapsed = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let r = recorder else { return }
        r.updateMeters()
        // dB (-160…0) to 0…1, with the useful range around speech.
        let db = r.averagePower(forChannel: 0)
        let level = max(0, min(1, (db + 50) / 50))
        levels.append(level)
        if levels.count > 120 { levels.removeFirst(levels.count - 120) }
        elapsed = r.currentTime
    }

    /// Stops and returns the recorded file (nil when nothing was recorded).
    func stop() -> URL? {
        timer?.invalidate()
        timer = nil
        guard let r = recorder else { return nil }
        r.stop()
        recorder = nil
        isRecording = false
        return fileURL
    }
}

/// Plays an audio attachment.
@MainActor
final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published var current: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var rate: Float = 1 { didSet { player?.rate = rate } }
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadedRevision: Int?

    func load(_ data: Data, revision: Int) {
        guard loadedRevision != revision else { return }
        stop()
        loadedRevision = revision
        player = try? AVAudioPlayer(data: data)
        player?.enableRate = true
        player?.delegate = self
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        current = 0
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let p = player else { return }
        if p.currentTime >= p.duration - 0.05 { p.currentTime = 0 }
        p.rate = rate
        p.play()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.current = self?.player?.currentTime ?? 0 }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        pause()
        player?.stop()
    }

    func seek(to t: TimeInterval) {
        player?.currentTime = max(0, min(t, duration))
        current = player?.currentTime ?? 0
    }

    func skip(_ delta: TimeInterval) { seek(to: current + delta) }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated {
            pause()
            current = duration
        }
    }
}

/// Audio block: records, plays back with a waveform and transcribes locally.
struct AudioBlockView: View {
    @ObservedObject var block: BlockModel
    @ObservedObject var doc: NoteDocument
    @EnvironmentObject var theme: ThemeManager
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var playback = AudioPlayback()
    @State private var peaks: [Float] = []
    @State private var error: String?
    @State private var transcribing: String?
    @State private var showTranscript = true

    /// A new block that starts recording as soon as it appears.
    static func recordingBlock() -> BlockModel {
        let b = BlockModel(kind: .audio)
        b.mode = "record"
        return b
    }

    private var attachment: FolioArchive.Attachment? { block.attachmentID.flatMap { doc.attachments[$0] } }

    var body: some View {
        EmbedCard(title: attachment?.header.filename ?? "Audioaufnahme", icon: "waveform",
                  height: .constant(0), resizable: false, onCommit: {}) {
            if attachment != nil { headerActions }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if attachment == nil { recorderView } else { playerView }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if let transcribing {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(transcribing).font(.caption).foregroundStyle(.secondary) }
                }
                if let transcript = block.output, !transcript.isEmpty { transcriptView(transcript) }
            }
            .padding(12)
        }
        .onAppear(perform: appear)
        .onDisappear(perform: disappear)
        .onChange(of: block.revision) { loadPlayer() }
    }

    // MARK: Recording

    private var recorderView: some View {
        HStack(spacing: 14) {
            Button(action: toggleRecording) {
                ZStack {
                    Circle().fill(Color.red.opacity(recorder.isRecording ? 0.18 : 1)).frame(width: 40, height: 40)
                    if recorder.isRecording {
                        RoundedRectangle(cornerRadius: 4).fill(Color.red).frame(width: 14, height: 14)
                    } else {
                        Circle().fill(Color.white).frame(width: 14, height: 14)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(recorder.isRecording ? "Aufnahme beenden" : "Aufnahme starten")
            if recorder.isRecording {
                LevelBars(levels: recorder.levels, color: .red).frame(height: 32)
                Text(AudioAnalysis.format(recorder.elapsed)).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            } else {
                Text("Aufnahme starten").foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func toggleRecording() {
        if recorder.isRecording { finishRecording() } else { startRecording() }
    }

    private func startRecording() {
        error = nil
        Task {
            do { try await recorder.start() } catch { self.error = error.localizedDescription }
        }
    }

    private func finishRecording() {
        guard let url = recorder.stop() else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url), data.count > 1_000 else {
            error = "Die Aufnahme ist leer."
            return
        }
        let name = "Aufnahme \(Date().formatted(date: .numeric, time: .shortened)).m4a"
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        block.attachmentID = doc.addAttachment(filename: name, typeIdentifier: "com.apple.m4a-audio", data: data)
        block.revision += 1
        doc.markDirty()
    }

    // MARK: Playback

    private var playerView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button { playback.toggle() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .help(playback.isPlaying ? "Pause" : "Abspielen")
                Waveform(peaks: peaks, progress: playback.duration > 0 ? playback.current / playback.duration : 0,
                         color: theme.accent) { fraction in playback.seek(to: fraction * playback.duration) }
                    .frame(height: 36)
                Text("\(AudioAnalysis.format(playback.current)) / \(AudioAnalysis.format(playback.duration))")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        Button { playback.skip(-15) } label: { Label("15 s zurück", systemImage: "gobackward.15") }.help("15 Sekunden zurück")
        Button { playback.skip(15) } label: { Label("15 s vor", systemImage: "goforward.15") }.help("15 Sekunden vor")
        Menu {
            ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { r in
                Button { playback.rate = Float(r) } label: {
                    Text("\(r.formatted())×") + Text(playback.rate == Float(r) ? "  ✓" : "")
                }
            }
        } label: {
            Text("\(Double(playback.rate).formatted())×").font(.system(size: 11.5, weight: .semibold, design: .rounded))
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Wiedergabegeschwindigkeit")
        Menu {
            ForEach(Transcriber.languages, id: \.identifier) { locale in
                Button(Transcriber.name(of: locale)) { transcribe(locale) }
            }
        } label: {
            Label("Transkribieren", systemImage: "text.bubble")
        } primaryAction: {
            transcribe(selectedLocale)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(transcribing != nil)
        .help("Lokal transkribieren (\(Transcriber.name(of: selectedLocale))) – gedrückt halten: andere Sprache")
        Button { AttachmentSync.open(block, in: doc) } label: { Label("Öffnen", systemImage: "arrow.up.forward.app") }
            .help("Im Standardprogramm öffnen")
    }

    // MARK: Transcript

    private var selectedLocale: Locale {
        block.language.isEmpty || block.language == "python" ? Locale.current : Locale(identifier: block.language)
    }

    private func transcribe(_ locale: Locale) {
        guard let att = attachment, let url = AttachmentSync.materialize(att, noteID: doc.id) else {
            error = "Die Audiodatei fehlt."
            return
        }
        error = nil
        transcribing = "Bereite die Spracherkennung vor …"
        block.language = locale.identifier
        Task {
            do {
                let text = try await Transcriber.transcribe(url, locale: locale) { transcribing = $0 }
                block.output = text
                showTranscript = true
                doc.markDirty()
            } catch {
                self.error = error.localizedDescription
            }
            transcribing = nil
        }
    }

    private func transcriptView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { withAnimation(Motion.quick) { showTranscript.toggle() } } label: {
                    Label("Transkript", systemImage: showTranscript ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                Spacer()
                Button("In Notiz übernehmen") { insertTranscript(text) }
                    .help("Das Transkript als Text unter der Aufnahme einfügen")
                Button { copy(text) } label: { Image(systemName: "doc.on.doc") }.help("Kopieren")
                Button { block.output = nil; doc.markDirty() } label: { Image(systemName: "xmark") }.help("Transkript verwerfen")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            if showTranscript {
                Text(text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func insertTranscript(_ text: String) {
        let attrs = theme.bodyAttributes
        let s = NSAttributedString(string: text, attributes: attrs)
        guard let i = doc.blocks.firstIndex(where: { $0.id == block.id }) else { return }
        if i + 1 < doc.blocks.count, doc.blocks[i + 1].kind == .text {
            let next = doc.blocks[i + 1]
            let combined = NSMutableAttributedString(attributedString: s)
            if next.storage.length > 0 { combined.append(NSAttributedString(string: "\n", attributes: attrs)) }
            next.storage.insert(combined, at: 0)
            next.revision += 1
            FormattingController.shared.focus(blockID: next.id)
        } else {
            doc.insert(.text(s), after: block.id)
        }
        doc.markDirty()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Lifecycle

    private func appear() {
        if attachment == nil, block.mode == "record" {
            block.mode = ""
            startRecording()
        }
        loadPlayer()
    }

    /// Leaving the note (or deleting the block) while recording keeps what was recorded so far.
    private func disappear() {
        playback.stop()
        if recorder.isRecording, doc.block(block.id) != nil { finishRecording() } else { _ = recorder.stop() }
    }

    private func loadPlayer() {
        guard let att = attachment else { return }
        playback.load(att.data, revision: block.revision)
        let id = att.id, noteID = doc.id
        guard let url = AttachmentSync.materialize(att, noteID: noteID) else { return }
        Task.detached(priority: .utility) {
            let p = (try? AudioAnalysis.peaks(of: url, buckets: 90)) ?? []
            await MainActor.run { if block.attachmentID == id { peaks = p } }
        }
    }
}

/// Bars of the live input level while recording (newest on the right).
struct LevelBars: View {
    var levels: [Float]
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let count = max(Int(geo.size.width / 4), 1)
            let shown = Array(levels.suffix(count))
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<count, id: \.self) { i in
                    let idx = i - (count - shown.count)
                    let v = idx >= 0 ? CGFloat(shown[idx]) : 0
                    Capsule().fill(color.opacity(0.8)).frame(width: 2.5, height: max(2, v * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }
}

/// Waveform of a recording; the played part is tinted, a click or drag seeks.
struct Waveform: View {
    var peaks: [Float]
    var progress: Double
    var color: Color
    var onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let bars = peaks.isEmpty ? Array(repeating: Float(0.15), count: 60) : peaks
            HStack(alignment: .center, spacing: 2) {
                ForEach(bars.indices, id: \.self) { i in
                    let played = Double(i) / Double(bars.count) < progress
                    Capsule()
                        .fill(played ? color : Color.secondary.opacity(0.35))
                        .frame(height: max(3, CGFloat(bars[i]) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                onSeek(min(max(v.location.x / geo.size.width, 0), 1))
            })
        }
    }
}
