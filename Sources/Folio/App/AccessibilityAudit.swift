import AppKit

/// Walks the accessibility tree of the visible windows and reports what VoiceOver users would miss (#60):
/// controls without a name, and the total of controls checked.
@MainActor
enum AccessibilityAudit {
    struct Finding: CustomStringConvertible {
        var role: String
        var help: String
        var frame: NSRect
        var description: String { "\(role) ohne Namen (Hilfe: \(help.isEmpty ? "–" : help)) bei \(Int(frame.minX)),\(Int(frame.minY))" }
    }

    static let controlRoles: Set<NSAccessibility.Role> = [.button, .menuButton, .checkBox, .popUpButton, .radioButton, .textField, .slider, .incrementor]

    static func audit(_ root: Any) -> (checked: Int, findings: [Finding]) {
        var checked = 0
        var findings: [Finding] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: Any, depth: Int) {
            guard depth < 60, seen.count < 20_000, let obj = element as? NSObject, seen.insert(ObjectIdentifier(obj)).inserted else { return }
            if let el = element as? NSAccessibilityProtocol {
                let role = el.accessibilityRole() ?? .unknown
                // Scroller arrows and page areas are named by the system through their subrole.
                let systemPart = ["AXDecrementArrow", "AXIncrementArrow", "AXDecrementPage", "AXIncrementPage"].contains(el.accessibilitySubrole()?.rawValue ?? "")
                if controlRoles.contains(role), !systemPart, !(el.isAccessibilityElement() == false) {
                    checked += 1
                    let label = text(of: el, "accessibilityLabel")
                    let title = text(of: el, "accessibilityTitle")
                    let value = role == .textField ? text(of: el, "accessibilityPlaceholderValue") : ""
                    if label.trimmingCharacters(in: .whitespaces).isEmpty && title.isEmpty && value.isEmpty {
                        var info = el.accessibilityHelp() ?? ""
                        if info.isEmpty {
                            let sub = el.accessibilitySubrole()?.rawValue ?? ""
                            let ident = el.accessibilityIdentifier()
                            let kids = (el.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityProtocol)?.accessibilityRole()?.rawValue }
                            info = "\(type(of: el)) \(sub) \(ident) Kinder: \(kids) Größe \(el.accessibilityFrame().size)"
                        }
                        findings.append(Finding(role: role.rawValue, help: info, frame: el.accessibilityFrame()))
                    }
                }
            }
            let children = (element as? NSAccessibilityProtocol)?.accessibilityChildren() ?? []
            for c in children { visit(c, depth: depth + 1) }
        }
        visit(root, depth: 0)
        print("A11Y visited \(seen.count) elements"); fflush(stdout)
        return (checked, findings)
    }

    /// Reads a text attribute without assuming its type (some elements answer with attributed strings).
    static func text(of element: Any, _ selector: String) -> String {
        guard let obj = element as? NSObject, obj.responds(to: NSSelectorFromString(selector)),
              let value = obj.perform(NSSelectorFromString(selector))?.takeUnretainedValue() else { return "" }
        if let s = value as? NSString { return s as String }
        if let a = value as? NSAttributedString { return a.string }
        return ""
    }

    static func run() {
        print("A11Y start"); fflush(stdout)
        var total = 0, missing = 0
        // SwiftUI builds its accessibility tree only for assistive apps; this tells it one is listening.
        NSApp.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        for w in NSApp.windows where w.isVisible {
            let r = audit(w.contentView as Any)
            total += r.checked
            missing += r.findings.count
            for f in r.findings { print("A11Y", f); fflush(stdout) }
        }
        print("A11Y checked \(total) controls, \(missing) without name"); fflush(stdout)
    }
}
