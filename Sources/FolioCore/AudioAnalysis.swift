import AVFoundation
import Foundation

/// Reads audio files for the audio block: duration and a compact waveform.
public enum AudioAnalysis {
    public enum AudioError: LocalizedError {
        case unreadable(String)
        public var errorDescription: String? {
            if case .unreadable(let m) = self { return "Die Audiodatei kann nicht gelesen werden: \(m)" }
            return nil
        }
    }

    public static func duration(of url: URL) throws -> TimeInterval {
        do {
            let file = try AVAudioFile(forReading: url)
            return Double(file.length) / file.processingFormat.sampleRate
        } catch {
            throw AudioError.unreadable(error.localizedDescription)
        }
    }

    /// Peak level (0…1) of `buckets` equal slices of the file, for drawing a waveform.
    public static func peaks(of url: URL, buckets: Int = 80) throws -> [Float] {
        guard buckets > 0 else { return [] }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw AudioError.unreadable(error.localizedDescription) }
        let total = file.length
        guard total > 0 else { return Array(repeating: 0, count: buckets) }
        let format = file.processingFormat
        let perBucket = max(AVAudioFrameCount(total / AVAudioFramePosition(buckets)), 1)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: perBucket) else { return [] }
        var peaks: [Float] = []
        peaks.reserveCapacity(buckets)
        for _ in 0..<buckets {
            buffer.frameLength = 0
            do { try file.read(into: buffer, frameCount: perBucket) } catch { break }
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            var peak: Float = 0
            for c in 0..<Int(format.channelCount) {
                let samples = channels[c]
                // Every 4th sample is plenty for a thumbnail and keeps long recordings fast.
                var i = 0
                while i < Int(buffer.frameLength) {
                    peak = max(peak, abs(samples[i]))
                    i += 4
                }
            }
            peaks.append(min(peak, 1))
        }
        while peaks.count < buckets { peaks.append(0) }
        // Normalize so quiet recordings still show a shape.
        if let top = peaks.max(), top > 0.0001 { peaks = peaks.map { $0 / top } }
        return peaks
    }

    /// "1:05" or "1:02:03".
    public static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Turns the segments a speech recognizer returns into readable paragraphs.
public enum TranscriptFormatter {
    /// Joins segments with single spaces and starts a new paragraph after a pause longer than `pause` seconds.
    public static func join(_ segments: [(text: String, start: TimeInterval?, end: TimeInterval?)], pause: TimeInterval = 2.5) -> String {
        var out = ""
        var lastEnd: TimeInterval?
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if out.isEmpty {
                out = text
            } else if let s = seg.start, let e = lastEnd, s - e > pause {
                out += "\n\n" + text
            } else {
                out += " " + text
            }
            if let e = seg.end { lastEnd = e }
        }
        return out
    }
}
