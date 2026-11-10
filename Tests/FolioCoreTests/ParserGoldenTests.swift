import XCTest
@testable import FolioCore

/// Compiler messages and completion contexts compared with a stored result (#152). FOLIO_WRITE_GOLDEN=1 rewrites it.
final class ParserGoldenTests: XCTestCase {
    private let outputs: [(String, String, String)] = [
        ("leer", "main.py", ""),
        ("python", "main.py", "Traceback (most recent call last):\n  File \"/tmp/x/main.py\", line 7, in <module>\n    f()\n  File \"/tmp/x/main.py\", line 3, in f\n    return 1 / 0\nZeroDivisionError: division by zero"),
        ("python sitzung", "<block>", "  File \"<block>\", line 2\n    x = (\n        ^\nSyntaxError: '(' was never closed"),
        ("syntaxfehler ohne datei", "main.py", "  line 4\nSyntaxError: invalid syntax"),
        ("gcc", "main.c", "main.c:3:5: error: use of undeclared identifier 'x'\nmain.c:3:5: warning: doppelt\n./main.c:9:1: warning: unused 'y' ä😀\nmain.c:12:"),
        ("javac", "Main.java", "Main.java:5: error: ';' expected\n        int x = 1\n                 ^"),
        ("rust", "main.rs", "error[E0425]: cannot find value `y` in this scope\n --> main.rs:3:13\nwarning: unused variable\n --> main.rs:2:9"),
        ("shell", "main.sh", "main.sh: line 4: foo: command not found"),
        ("ruby", "main.rb", "main.rb:6:in `block': undefined local variable (NameError)"),
        ("node", "main.js", "/tmp/main.js:3\n  foo();\n  ^\n\nReferenceError: foo is not defined\n    at Object.<anonymous> (/tmp/main.js:3:3)"),
        ("node stack", "main.js", "TypeError: x is not a function\n    at f (/tmp/main.js:8:2)"),
        ("zeilen begrenzt", "main.c", "main.c:99:1: error: weit hinter dem Ende"),
        ("andere datei", "main.c", "other.c:3:1: error: nicht unsere Datei"),
    ]

    private let contexts: [(String, String, String)] = [
        ("swift", "let s = text.cou", "swift"), ("python", "import os\nos.path.jo", "python"), ("kette", "a.b(c).d[0].", "javascript"),
        ("cpp", "std::vec", "cpp"), ("zeiger", "p->na", "c"), ("leer", "", "python"), ("unicode", "größe = 1\ngrö", "python"),
        ("klammer", "f(a, b.c", "python"), ("ohne punkt", "x = 1 + y", "python"), ("dollar", "$el.$na", "javascript"),
    ]

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    }

    private func compare(_ text: String, with name: String) throws {
        if ProcessInfo.processInfo.environment["FOLIO_WRITE_GOLDEN"] != nil { try text.write(to: fixture(name), atomically: true, encoding: .utf8) }
        XCTAssertEqual(text, try String(contentsOf: fixture(name), encoding: .utf8))
    }

    func testDiagnosticsMatchStoredResult() throws {
        let text = outputs.map { name, file, output in
            let found = DiagnosticParser.parse(output, fileName: file, lineCount: 50)
            return "== \(name)\n" + found.map { "\($0.line):\($0.column.map(String.init) ?? "-") \($0.severity) \($0.message)" }.joined(separator: "\n")
        }.joined(separator: "\n") + "\n"
        try compare(text, with: "diagnostics.txt")
    }

    func testCompletionContextsMatchStoredResult() throws {
        let text = contexts.map { name, code, language in
            let c = CompletionContext(code: code, offset: (code as NSString).length, language: language)
            return "\(name): receiver=\(c.receiver ?? "-") prefix=\(c.prefix) line=\(c.line) column=\(c.column)"
        }.joined(separator: "\n") + "\n"
        try compare(text, with: "completion-contexts.txt")
    }

    func testContextInTheMiddleOfTheCode() {
        let c = CompletionContext(code: "a.bc + d", offset: 4, language: "python")
        XCTAssertEqual(c.receiver, "a")
        XCTAssertEqual(c.prefix, "bc")
        XCTAssertEqual(CompletionContext(code: "x", offset: 99, language: "python").offset, 1)
    }
}

/// Reading `javap -public` output (#152).
final class JavapParserTests: XCTestCase {
    func testMembersWithGenericsStaticsAndDuplicates() {
        let text = """
        Compiled from "ArrayList.java"
        public class java.util.ArrayList<E> extends java.util.AbstractList<E> implements java.util.List<E> {
          public java.util.ArrayList(int);
          public int size();
          public boolean add(E);
          public void add(int, E);
          public static <T> java.util.List<T> of(T...);
          public static final int MAX;
          public java.util.Map<java.lang.String, java.util.List<E>> grouped();
          public interface java.util.Inner;
          protected void hidden();
        }
        """
        let members = IntrospectionCompleter.parseJavap(text)
        XCTAssertEqual(members.map(\.item.label), ["size", "add", "of", "MAX", "grouped"])
        XCTAssertEqual(members.map(\.isStatic), [false, false, true, true, false])
        XCTAssertEqual(members[0].item.detail, "int size()")
        XCTAssertEqual(members[0].item.insertText, "size()")
        XCTAssertEqual(members[1].item.insertText, "add(")
        XCTAssertEqual(members[3].item.kind, .field)
        XCTAssertEqual(members[4].type, "java.util.Map")
    }

    func testEmptyAndUnicodeOutput() {
        XCTAssertEqual(IntrospectionCompleter.parseJavap("").count, 0)
        XCTAssertEqual(IntrospectionCompleter.parseJavap("Fehler: Klasse nicht gefunden: Ä").count, 0)
        XCTAssertEqual(IntrospectionCompleter.parseJavap("  public int größe();").map(\.item.label), ["größe()"].map { _ in "größe" })
    }
}
