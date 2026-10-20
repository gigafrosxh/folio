import Foundation

/// JavaScript calls for the local KaTeX and Mermaid pages (Resources/Web/render.html).
///
/// The page exposes `folioRender(kind, source, options)`; it answers through the `folio` message
/// handler with `{ok, width, height, error, svg}`. Everything runs offline from files in the app bundle.
public enum RenderScript {
    public enum Kind: String, Sendable {
        case math, diagram
    }

    public struct Options: Sendable, Equatable {
        public var dark: Bool
        public var fontSize: Double
        /// Formula on its own line (display style) instead of inline style.
        public var displayMode: Bool

        public init(dark: Bool = false, fontSize: Double = 18, displayMode: Bool = true) {
            self.dark = dark
            self.fontSize = fontSize
            self.displayMode = displayMode
        }
    }

    /// The call that renders `source`; the source is passed as a JSON string literal, so quotes,
    /// backslashes, line breaks and `</script>` in it can never break out of the call.
    public static func call(_ kind: Kind, source: String, options: Options = Options()) -> String {
        let opts: [String: Any] = ["dark": options.dark, "fontSize": options.fontSize, "displayMode": options.displayMode]
        return "folioRender(\(jsString(kind.rawValue)), \(jsString(source)), \(json(opts)))"
    }

    public static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
        var text = String(decoding: data, as: UTF8.self)
        text = String(text.dropFirst().dropLast())
        // U+2028/2029 are line breaks inside JS string literals in older engines; "</" could end a script tag.
        return text.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            .replacingOccurrences(of: "</", with: "<\\/")
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Result posted back by the page.
    public struct Result: Sendable, Equatable {
        public var ok: Bool
        /// Tight bounds of the drawing in page coordinates.
        public var x: Double = 0
        public var y: Double = 0
        public var width: Double
        public var height: Double
        public var error: String?
        /// The rendered SVG (diagrams only), for exporting.
        public var svg: String?
        /// Height of the whole rendered area (what the view needs to show it).
        public var pageHeight: Double = 0
        /// The page finished loading (first message, before any render).
        public var ready = false

        public init(ok: Bool, width: Double = 0, height: Double = 0, error: String? = nil, svg: String? = nil) {
            self.ok = ok
            self.width = width
            self.height = height
            self.error = error
            self.svg = svg
        }

        public init?(message body: Any) {
            guard let d = body as? [String: Any], let ok = d["ok"] as? Bool else { return nil }
            self.init(ok: ok,
                      width: (d["width"] as? NSNumber)?.doubleValue ?? 0,
                      height: (d["height"] as? NSNumber)?.doubleValue ?? 0,
                      error: (d["error"] as? String).map(Self.cleanError),
                      svg: d["svg"] as? String)
            x = (d["x"] as? NSNumber)?.doubleValue ?? 0
            y = (d["y"] as? NSNumber)?.doubleValue ?? 0
            pageHeight = (d["pageHeight"] as? NSNumber)?.doubleValue ?? height
            ready = d["ready"] as? Bool ?? false
        }

        /// KaTeX and Mermaid errors carry long prefixes and the whole source; keep the useful first lines.
        static func cleanError(_ raw: String) -> String {
            var s = raw.replacingOccurrences(of: "KaTeX parse error: ", with: "")
            let lines = s.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            s = lines.prefix(4).joined(separator: "\n")
            return s.count > 400 ? String(s.prefix(400)) + " …" : s
        }
    }
}

/// Starters for new diagram and formula blocks.
public enum RenderSamples {
    public static let math = #"\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}"#
    public static let diagram = """
    flowchart LR
        Idee --> Notiz
        Notiz --> Code
        Notiz --> Diagramm
    """

    /// The diagram type a Mermaid source declares (first keyword), e.g. "flowchart" or "sequenceDiagram".
    public static func diagramType(of source: String) -> String? {
        var inFrontMatter = false
        for line in source.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "---" { inFrontMatter.toggle(); continue }
            if inFrontMatter || t.isEmpty || t.hasPrefix("%%") { continue }
            return t.split(whereSeparator: { $0.isWhitespace || $0 == ";" }).first.map(String.init)
        }
        return nil
    }
}
