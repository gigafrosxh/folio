import SwiftUI

/// VoiceOver support (#60).
enum A11y {
    /// What VoiceOver should say for a button whose tooltip is `help`: without the shortcut in brackets
    /// and without the explanation after a dash ("Fett (⌘B)" → "Fett").
    static func label(_ help: String) -> String {
        var s = help
        if let dash = s.range(of: " – ") { s = String(s[..<dash.lowerBound]) }
        s = s.replacingOccurrences(of: #"\s*\([^)]*[⌘⌥⌃⇧↩][^)]*\)"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }
}

extension View {
    /// Tooltip plus a spoken name, for buttons that only show an icon.
    func helpLabel(_ help: String) -> some View {
        self.help(help).accessibilityLabel(Text(A11y.label(help)))
    }
}
