import AppKit
import SwiftUI
import FolioCore

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Hell"
        case .dark: return "Dunkel"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum FloatingStyle: String, Codable, CaseIterable, Identifiable {
    case glass, material, solid
    var id: String { rawValue }
    var label: String {
        switch self {
        case .glass: return "Glas"
        case .material: return "Milchglas"
        case .solid: return "Deckend"
        }
    }
}

/// Colors for code blocks, as hex strings so themes can be stored and edited.
struct CodeTheme: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var isDark: Bool
    var background: String
    var foreground: String
    var keyword: String
    var string: String
    var comment: String
    var number: String
    var type: String
    var function: String
    var attribute: String
    var outputBackground: String

    func color(for kind: TokenKind) -> NSColor {
        let hex: String
        switch kind {
        case .keyword: hex = keyword
        case .string: hex = string
        case .comment: hex = comment
        case .number: hex = number
        case .type: hex = type
        case .function: hex = function
        case .attribute: hex = attribute
        }
        return NSColor(hex: hex) ?? .textColor
    }

    var backgroundColor: NSColor { NSColor(hex: background) ?? .textBackgroundColor }
    var foregroundColor: NSColor { NSColor(hex: foreground) ?? .textColor }

    static let presets: [CodeTheme] = [
        CodeTheme(id: "xcode-light", name: "Xcode Hell", isDark: false, background: "#FFFFFF", foreground: "#1F1F24",
                  keyword: "#9B2393", string: "#C41A16", comment: "#5D6C79", number: "#1C00CF", type: "#0B4F79",
                  function: "#326D74", attribute: "#815F03", outputBackground: "#F4F4F6"),
        CodeTheme(id: "xcode-dark", name: "Xcode Dunkel", isDark: true, background: "#1F1F24", foreground: "#FFFFFF",
                  keyword: "#FF7AB2", string: "#FF8170", comment: "#7F8C98", number: "#D9C97C", type: "#6BDFFF",
                  function: "#67B7A4", attribute: "#FFA14F", outputBackground: "#18181C"),
        CodeTheme(id: "github-light", name: "GitHub Hell", isDark: false, background: "#F6F8FA", foreground: "#24292F",
                  keyword: "#CF222E", string: "#0A3069", comment: "#6E7781", number: "#0550AE", type: "#953800",
                  function: "#8250DF", attribute: "#116329", outputBackground: "#EEF1F4"),
        CodeTheme(id: "monokai", name: "Monokai", isDark: true, background: "#272822", foreground: "#F8F8F2",
                  keyword: "#F92672", string: "#E6DB74", comment: "#75715E", number: "#AE81FF", type: "#66D9EF",
                  function: "#A6E22E", attribute: "#FD971F", outputBackground: "#1E1F1A"),
        CodeTheme(id: "dracula", name: "Dracula", isDark: true, background: "#282A36", foreground: "#F8F8F2",
                  keyword: "#FF79C6", string: "#F1FA8C", comment: "#6272A4", number: "#BD93F9", type: "#8BE9FD",
                  function: "#50FA7B", attribute: "#FFB86C", outputBackground: "#21222C"),
        CodeTheme(id: "solarized-light", name: "Solarized Hell", isDark: false, background: "#FDF6E3", foreground: "#586E75",
                  keyword: "#859900", string: "#2AA198", comment: "#93A1A1", number: "#D33682", type: "#B58900",
                  function: "#268BD2", attribute: "#CB4B16", outputBackground: "#EEE8D5"),
        CodeTheme(id: "solarized-dark", name: "Solarized Dunkel", isDark: true, background: "#002B36", foreground: "#93A1A1",
                  keyword: "#859900", string: "#2AA198", comment: "#586E75", number: "#D33682", type: "#B58900",
                  function: "#268BD2", attribute: "#CB4B16", outputBackground: "#00222B"),
        CodeTheme(id: "nord", name: "Nord", isDark: true, background: "#2E3440", foreground: "#D8DEE9",
                  keyword: "#81A1C1", string: "#A3BE8C", comment: "#616E88", number: "#B48EAD", type: "#8FBCBB",
                  function: "#88C0D0", attribute: "#D08770", outputBackground: "#272C36"),
    ]
}

/// Everything the user can customize. Unknown/missing keys fall back to defaults so old settings keep loading.
struct ThemeSettings: Codable, Equatable {
    var appearance: AppearanceMode = .system
    var accentHex = "#E5A50A"
    var editorFont = "System"
    var editorFontSize: Double = 15
    var lineSpacing: Double = 4
    var editorWidth: Double = 760
    var codeFont = "SF Mono"
    var codeFontSize: Double = 13
    var codeThemeLight = "xcode-light"
    var codeThemeDark = "xcode-dark"
    var customCodeThemes: [CodeTheme] = []
    var codeCornerRadius: Double = 12
    var showLineNumbers = true
    var floatingStyle: FloatingStyle = .glass
    var cornerRadius: Double = 16
    var shadows = true
    var runTimeout: Double = 30
    var interpreterOverrides: [String: String] = [:]
    var libraryPath: String = ThemeSettings.defaultLibraryPath
    /// Grey inline completions from Apple Intelligence (Foundation Models), accepted with Tab.
    var aiPredictions = true
    /// The system's own inline word predictions in text fields.
    var systemPredictions = true
    /// Grey code completions in code blocks (needs `aiPredictions`).
    var codePredictions = true
    /// IDE-style completion list in code blocks.
    var codeCompletion = true
    /// Rebound tool shortcuts: action id → "ctrl+c". Missing entries use the defaults.
    var shortcuts: [String: String] = [:]
    /// Subtle UI animations (also off when the system asks to reduce motion).
    var animations = true
    /// Database connections created in Folio, offered in SQL code blocks (passwords stay in the Keychain).
    var savedConnections: [DatabaseConnection] = []
    /// Look for a new Folio release on GitHub at every start and ask whether to install it. On by default;
    /// a new key name, so installations that stored the old opt-in value (`checkUpdatesOnLaunch`) get it too.
    var askForUpdatesOnLaunch = true
    /// Menu bar icon with search and quick capture (#85).
    var menuBarIcon = true
    /// Global quick capture shortcut as stored KeyCombo; "" = default (⌃⌥⌘N), "off" = none (#86).
    var captureHotKey = ""
    /// Code runs: output kept per run (KB), memory limit for the process tree (MB, 0 = none),
    /// stop processes a program leaves behind (#27, #32).
    var maxOutputKB: Double = 1000
    var maxMemoryMB: Double = 0
    var killOrphans = true
    /// Days a deleted note stays in Folio's trash (0 = until emptied by hand).
    var trashRetentionDays = 30
    /// Automatic zip backups of the library.
    var backupsEnabled = true
    /// Hours between automatic backups.
    var backupIntervalHours: Double = 24
    /// Folder for backups; empty = ~/Library/Application Support/Folio/Backups.
    var backupFolder = ""
    /// Widgets (#83): show previews and checklist items. Off by default – widgets show only titles.
    var widgetShowContent = false
    /// Note and checklist chosen for the widgets („Im Widget zeigen“); "" = automatic (#81, #82).
    var widgetNote = ""
    var widgetChecklist = ""
    /// Daily notes (#117): folder below the library and template id ("" = none).
    var dailyFolder = "Tagesnotizen"
    var dailyTemplate = ""

    static var defaultLibraryPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Folio").path
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ThemeSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        appearance = v(.appearance, d.appearance)
        accentHex = v(.accentHex, d.accentHex)
        editorFont = v(.editorFont, d.editorFont)
        editorFontSize = v(.editorFontSize, d.editorFontSize)
        lineSpacing = v(.lineSpacing, d.lineSpacing)
        editorWidth = v(.editorWidth, d.editorWidth)
        codeFont = v(.codeFont, d.codeFont)
        codeFontSize = v(.codeFontSize, d.codeFontSize)
        codeThemeLight = v(.codeThemeLight, d.codeThemeLight)
        codeThemeDark = v(.codeThemeDark, d.codeThemeDark)
        customCodeThemes = v(.customCodeThemes, d.customCodeThemes)
        codeCornerRadius = v(.codeCornerRadius, d.codeCornerRadius)
        showLineNumbers = v(.showLineNumbers, d.showLineNumbers)
        floatingStyle = v(.floatingStyle, d.floatingStyle)
        cornerRadius = v(.cornerRadius, d.cornerRadius)
        shadows = v(.shadows, d.shadows)
        runTimeout = v(.runTimeout, d.runTimeout)
        interpreterOverrides = v(.interpreterOverrides, d.interpreterOverrides)
        libraryPath = v(.libraryPath, d.libraryPath)
        aiPredictions = v(.aiPredictions, d.aiPredictions)
        systemPredictions = v(.systemPredictions, d.systemPredictions)
        codePredictions = v(.codePredictions, d.codePredictions)
        codeCompletion = v(.codeCompletion, d.codeCompletion)
        shortcuts = v(.shortcuts, d.shortcuts)
        animations = v(.animations, d.animations)
        savedConnections = v(.savedConnections, d.savedConnections)
        askForUpdatesOnLaunch = v(.askForUpdatesOnLaunch, d.askForUpdatesOnLaunch)
        trashRetentionDays = v(.trashRetentionDays, d.trashRetentionDays)
        maxOutputKB = v(.maxOutputKB, d.maxOutputKB)
        menuBarIcon = v(.menuBarIcon, d.menuBarIcon)
        captureHotKey = v(.captureHotKey, d.captureHotKey)
        maxMemoryMB = v(.maxMemoryMB, d.maxMemoryMB)
        killOrphans = v(.killOrphans, d.killOrphans)
        backupsEnabled = v(.backupsEnabled, d.backupsEnabled)
        backupIntervalHours = v(.backupIntervalHours, d.backupIntervalHours)
        backupFolder = v(.backupFolder, d.backupFolder)
        widgetShowContent = v(.widgetShowContent, d.widgetShowContent)
        widgetNote = v(.widgetNote, d.widgetNote)
        widgetChecklist = v(.widgetChecklist, d.widgetChecklist)
        dailyFolder = v(.dailyFolder, d.dailyFolder)
        dailyTemplate = v(.dailyTemplate, d.dailyTemplate)
    }
}

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    private static let key = "folio.theme.v1"

    @Published var settings: ThemeSettings {
        didSet { if settings != oldValue { persist() } }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let s = try? JSONDecoder().decode(ThemeSettings.self, from: data) {
            settings = s
        } else {
            settings = ThemeSettings()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    var accent: Color { Color(nsColor: accentNSColor) }
    var accentNSColor: NSColor { NSColor(hex: settings.accentHex) ?? .systemYellow }

    var allCodeThemes: [CodeTheme] { CodeTheme.presets + settings.customCodeThemes }

    func codeTheme(dark: Bool) -> CodeTheme {
        let id = dark ? settings.codeThemeDark : settings.codeThemeLight
        return allCodeThemes.first { $0.id == id } ?? CodeTheme.presets[dark ? 1 : 0]
    }

    // MARK: Fonts

    func bodyFont(size: CGFloat? = nil) -> NSFont {
        let s = size ?? CGFloat(settings.editorFontSize)
        if settings.editorFont != "System", let f = NSFont(name: settings.editorFont, size: s) { return f }
        return NSFont.systemFont(ofSize: s)
    }

    func codeFont() -> NSFont {
        let s = CGFloat(settings.codeFontSize)
        if let f = NSFont(name: settings.codeFont, size: s) { return f }
        return NSFont.monospacedSystemFont(ofSize: s, weight: .regular)
    }

    var bodyParagraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = CGFloat(settings.lineSpacing)
        p.paragraphSpacing = 2
        return p
    }

    var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont(), .foregroundColor: NSColor.textColor, .paragraphStyle: bodyParagraphStyle]
    }
}

// MARK: - Color helpers

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(round(c.redComponent * 255)), g = Int(round(c.greenComponent * 255)), b = Int(round(c.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

extension Binding where Value == String {
    /// Bridges a hex string to SwiftUI's `ColorPicker`.
    func asColor() -> Binding<Color> {
        Binding<Color>(
            get: { Color(nsColor: NSColor(hex: wrappedValue) ?? .gray) },
            set: { wrappedValue = NSColor($0).hexString }
        )
    }
}

// MARK: - Floating surfaces

struct FloatingSurface: ViewModifier {
    @EnvironmentObject var theme: ThemeManager
    var cornerRadius: CGFloat?
    var capsule = false

    func body(content: Content) -> some View {
        let radius = cornerRadius ?? CGFloat(theme.settings.cornerRadius)
        let shape = AnyShape(capsule ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))
        let shadow = theme.settings.shadows
        Group {
            switch theme.settings.floatingStyle {
            case .glass:
                if #available(macOS 26.0, *) {
                    content.glassEffect(.regular, in: shape)
                } else {
                    content.background(.regularMaterial, in: shape)
                }
            case .material:
                content.background(.regularMaterial, in: shape)
                    .overlay(shape.stroke(Color.primary.opacity(0.08)))
            case .solid:
                content.background(Color(nsColor: .controlBackgroundColor), in: shape)
                    .overlay(shape.stroke(Color.primary.opacity(0.08)))
            }
        }
        .shadow(color: .black.opacity(shadow ? 0.12 : 0), radius: shadow ? 14 : 0, y: shadow ? 6 : 0)
    }
}

extension View {
    func floating(cornerRadius: CGFloat? = nil) -> some View { modifier(FloatingSurface(cornerRadius: cornerRadius)) }
    func floatingCapsule() -> some View { modifier(FloatingSurface(capsule: true)) }
}
