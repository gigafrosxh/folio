import ComplexityCore
import Foundation

// complexity-check [--root <repo>] [--baseline <json>] [--report <md>] [--json <json>] [--update-baseline] [folders …]
// Measures Sources (without tests and generated code) and fails when a unit is new or worse above the limit (#156).
var root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
var baselineURL: URL?
var reportURL: URL?
var jsonURL: URL?
var updateBaseline = false
var folders: [String] = []
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--root": root = URL(fileURLWithPath: args.next() ?? ".")
    case "--baseline": baselineURL = args.next().map { URL(fileURLWithPath: $0) }
    case "--report": reportURL = args.next().map { URL(fileURLWithPath: $0) }
    case "--json": jsonURL = args.next().map { URL(fileURLWithPath: $0) }
    case "--update-baseline": updateBaseline = true
    default: folders.append(arg)
    }
}

let units = try ComplexityScanner.units(root: root, folders: folders.isEmpty ? ["Sources"] : folders, excluding: ["Tests/", ".build/"])
let baseline = baselineURL.flatMap { try? JSONDecoder().decode([String: Int].self, from: Data(contentsOf: $0)) } ?? [:]
let report = ComplexityReport(units: units, baseline: baseline)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

if let reportURL { try report.markdown.write(to: reportURL, atomically: true, encoding: .utf8) }
if let jsonURL { try encoder.encode(units).write(to: jsonURL) }
if updateBaseline, let baselineURL {
    try encoder.encode(report.newBaseline).write(to: baselineURL)
    print("Baseline geschrieben: \(report.newBaseline.count) Einheiten über \(ComplexityReport.limit).")
}

print("\(units.count) Einheiten geprüft, \(report.overLimit.count) über \(ComplexityReport.limit), \(report.violations.count) neu oder verschlechtert, \(report.resolved.count) aus der Baseline erledigt.")
for unit in report.violations { print("FEHLER \(unit.file):\(unit.line) \(unit.symbol): \(unit.score) (Grenzwert \(ComplexityReport.limit))") }
exit(report.violations.isEmpty || updateBaseline ? 0 : 1)
