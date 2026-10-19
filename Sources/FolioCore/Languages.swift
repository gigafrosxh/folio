import Foundation

/// A programming language Folio can highlight and, when a matching tool is installed, run.
public struct LanguageSpec: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var fileExtension: String
    public var keywords: Set<String>
    /// Built-in types/constants, colored like types.
    public var builtins: Set<String> = []
    public var lineComments: [String] = []
    public var blockComment: [String]? = nil   // [open, close]
    public var stringDelimiters: [String] = ["\"", "'"]
    public var caseInsensitive = false
    public var capitalizedAreTypes = true
    /// `@decorator` / `$variable` style tokens.
    public var attributePrefix: String? = nil
    /// Extra highlighting rules: (regex, kind, applied after strings/comments).
    public var extraRules: [Rule] = []
    /// Alternative ways to run code, tried in order. Each plan is a list of commands; placeholders:
    /// `{file}` source path, `{out}` compiled binary path, `{dir}` temporary working directory.
    public var runPlans: [[[String]]] = []

    public struct Rule: Sendable, Hashable {
        public var pattern: String
        public var kind: TokenKind
        public var afterStrings: Bool
        public init(_ pattern: String, _ kind: TokenKind, afterStrings: Bool = false) {
            self.pattern = pattern
            self.kind = kind
            self.afterStrings = afterStrings
        }
    }

    public var isRunnable: Bool { !runPlans.isEmpty }

    public static func == (a: LanguageSpec, b: LanguageSpec) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

public enum Languages {
    public static func spec(for id: String?) -> LanguageSpec {
        guard let id = id?.lowercased() else { return plain }
        return all.first { $0.id == id } ?? aliases[id].flatMap { a in all.first { $0.id == a } } ?? plain
    }

    static let aliases: [String: String] = [
        "py": "python", "js": "javascript", "ts": "typescript", "sh": "bash", "shell": "bash",
        "rb": "ruby", "c++": "cpp", "golang": "go", "rs": "rust", "kt": "kotlin", "md": "markdown",
        "yml": "yaml", "objc": "c", "htm": "html", "applescript": "applescript",
    ]

    public static let plain = LanguageSpec(id: "plain", name: "Text", fileExtension: "txt", keywords: [],
                                           stringDelimiters: [], capitalizedAreTypes: false)

    private static func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

    public static let all: [LanguageSpec] = [
        LanguageSpec(
            id: "python", name: "Python", fileExtension: "py",
            keywords: words("False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case self"),
            builtins: words("print len range int str float list dict set tuple bool open enumerate zip map filter sorted sum min max abs isinstance type super object Exception"),
            lineComments: ["#"], stringDelimiters: ["\"\"\"", "'''", "\"", "'"], attributePrefix: "@",
            runPlans: [[["python3", "-u", "{file}"]], [["python", "-u", "{file}"]]]
        ),
        LanguageSpec(
            id: "javascript", name: "JavaScript", fileExtension: "js",
            keywords: words("break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new of return super switch this throw try typeof var void while with yield async await static get set null undefined true false"),
            builtins: words("console Math JSON Promise Array Object String Number Boolean Map Set Date Error RegExp window document"),
            lineComments: ["//"], blockComment: ["/*", "*/"], stringDelimiters: ["`", "\"", "'"],
            runPlans: [[["node", "{file}"]], [["bun", "run", "{file}"]], [["deno", "run", "{file}"]]]
        ),
        LanguageSpec(
            id: "typescript", name: "TypeScript", fileExtension: "ts",
            keywords: words("break case catch class const continue debugger default delete do else enum export extends finally for function if implements import in instanceof interface let new of return super switch this throw try typeof var void while with yield async await static get set null undefined true false type namespace declare readonly private public protected abstract as keyof"),
            builtins: words("console Math JSON Promise Array Object String Number Boolean Map Set Date Error string number boolean any unknown never void"),
            lineComments: ["//"], blockComment: ["/*", "*/"], stringDelimiters: ["`", "\"", "'"], attributePrefix: "@",
            runPlans: [[["bun", "run", "{file}"]], [["deno", "run", "{file}"]], [["tsx", "{file}"]], [["node", "--experimental-strip-types", "{file}"]]]
        ),
        LanguageSpec(
            id: "swift", name: "Swift", fileExtension: "swift",
            keywords: words("associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private protocol public rethrows static struct subscript typealias var break case continue default defer do else fallthrough for guard if in repeat return switch where while as catch false is nil super self Self throw throws true try async await some any actor nonisolated mutating override final lazy weak unowned convenience required"),
            builtins: words("print String Int Double Float Bool Array Dictionary Set Optional Character Data URL Date"),
            lineComments: ["//"], blockComment: ["/*", "*/"], stringDelimiters: ["\"\"\"", "\""], attributePrefix: "@",
            runPlans: [[["swift", "{file}"]]]
        ),
        LanguageSpec(
            id: "ruby", name: "Ruby", fileExtension: "rb",
            keywords: words("BEGIN END alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require require_relative attr_accessor puts"),
            lineComments: ["#"], stringDelimiters: ["\"", "'"], attributePrefix: "@",
            runPlans: [[["ruby", "{file}"]]]
        ),
        LanguageSpec(
            id: "bash", name: "Bash", fileExtension: "sh",
            keywords: words("if then else elif fi case esac for select while until do done in function time return exit export local readonly declare echo printf cd source true false"),
            lineComments: ["#"], stringDelimiters: ["\"", "'"], capitalizedAreTypes: false, attributePrefix: "$",
            runPlans: [[["bash", "{file}"]]]
        ),
        LanguageSpec(
            id: "zsh", name: "Zsh", fileExtension: "zsh",
            keywords: words("if then else elif fi case esac for select while until do done in function time return exit export local readonly declare typeset echo print printf cd source true false"),
            lineComments: ["#"], stringDelimiters: ["\"", "'"], capitalizedAreTypes: false, attributePrefix: "$",
            runPlans: [[["zsh", "{file}"]]]
        ),
        LanguageSpec(
            id: "fish", name: "Fish", fileExtension: "fish",
            keywords: words("if else end for in while function return begin switch case and or not set echo printf string test true false"),
            lineComments: ["#"], stringDelimiters: ["\"", "'"], capitalizedAreTypes: false, attributePrefix: "$",
            runPlans: [[["fish", "{file}"]]]
        ),
        LanguageSpec(
            id: "c", name: "C", fileExtension: "c",
            keywords: words("auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while NULL true false bool"),
            builtins: words("printf scanf malloc free size_t uint8_t uint32_t int32_t int64_t uint64_t FILE"),
            lineComments: ["//"], blockComment: ["/*", "*/"], stringDelimiters: ["\"", "'"],
            extraRules: [LanguageSpec.Rule(#"^\s*#\s*\w+.*$"#, .attribute, afterStrings: false)],
            runPlans: [[["clang", "-std=c17", "-O1", "{file}", "-o", "{out}"], ["{out}"]], [["gcc", "{file}", "-o", "{out}"], ["{out}"]]]
        ),
        LanguageSpec(
            id: "cpp", name: "C++", fileExtension: "cpp",
            keywords: words("alignas alignof and auto bool break case catch char class const constexpr const_cast continue decltype default delete do double dynamic_cast else enum explicit export extern false float for friend goto if inline int long mutable namespace new noexcept nullptr operator or private protected public return short signed sizeof static static_cast struct switch template this throw true try typedef typename union unsigned using virtual void volatile while override final"),
            builtins: words("std cout cin endl string vector map set unique_ptr shared_ptr size_t"),
            lineComments: ["//"], blockComment: ["/*", "*/"], stringDelimiters: ["\"", "'"],
            extraRules: [LanguageSpec.Rule(#"^\s*#\s*\w+.*$"#, .attribute)],
            runPlans: [[["clang++", "-std=c++20", "-O1", "{file}", "-o", "{out}"], ["{out}"]], [["g++", "-std=c++20", "{file}", "-o", "{out}"], ["{out}"]]]
        ),
        LanguageSpec(
            id: "go", name: "Go", fileExtension: "go",
            keywords: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var true false nil iota"),
            builtins: words("fmt string int int64 float64 bool byte rune error make len cap append new panic"),
            lineComments: ["//"], blockComment: ["/*", "*/"], stringDelimiters: ["`", "\"", "'"],
            runPlans: [[["go", "run", "{file}"]]]
        ),
        LanguageSpec(
            id: "rust", name: "Rust", fileExtension: "rs",
            keywords: words("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while"),
            builtins: words("println print format vec String Vec Option Some None Result Ok Err Box i32 i64 u8 u32 u64 usize f32 f64 bool str"),
            lineComments: ["//"], blockComment: ["/*", "*/"], stringDelimiters: ["\""],
            extraRules: [LanguageSpec.Rule(#"\b\w+!"#, .function)],
            runPlans: [[["rustc", "-O", "{file}", "-o", "{out}"], ["{out}"]]]
        ),
        LanguageSpec(
            id: "java", name: "Java", fileExtension: "java",
            keywords: words("abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while var record true false null"),
            builtins: words("System String Integer List Map ArrayList HashMap Object"),
            lineComments: ["//"], blockComment: ["/*", "*/"], stringDelimiters: ["\"", "'"], attributePrefix: "@",
            runPlans: [[["java", "{file}"]]]
        ),
        LanguageSpec(
            id: "kotlin", name: "Kotlin", fileExtension: "kts",
            keywords: words("as break class continue do else false for fun if in interface is null object package return super this throw true try typealias typeof val var when while by catch constructor data enum finally get import init internal lateinit open override private protected public sealed set suspend"),
            lineComments: ["//"], blockComment: ["/*", "*/"], stringDelimiters: ["\"\"\"", "\"", "'"], attributePrefix: "@",
            runPlans: [[["kotlin", "{file}"]], [["kotlinc", "-script", "{file}"]]]
        ),
        LanguageSpec(
            id: "php", name: "PHP", fileExtension: "php",
            keywords: words("abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global goto if implements include instanceof interface isset list match namespace new or print private protected public require return static switch throw trait try unset use var while yield true false null"),
            lineComments: ["//", "#"], blockComment: ["/*", "*/"], stringDelimiters: ["\"", "'"], attributePrefix: "$",
            runPlans: [[["php", "{file}"]]]
        ),
        LanguageSpec(
            id: "perl", name: "Perl", fileExtension: "pl",
            keywords: words("my our local sub if elsif else unless while until for foreach do last next redo return use package print say die eval"),
            lineComments: ["#"], stringDelimiters: ["\"", "'"], capitalizedAreTypes: false, attributePrefix: "$",
            runPlans: [[["perl", "{file}"]]]
        ),
        LanguageSpec(
            id: "lua", name: "Lua", fileExtension: "lua",
            keywords: words("and break do else elseif end false for function goto if in local nil not or repeat return then true until while"),
            builtins: words("print pairs ipairs table string math require"),
            lineComments: ["--"], blockComment: ["--[[", "]]"], stringDelimiters: ["\"", "'"],
            runPlans: [[["lua", "{file}"]]]
        ),
        LanguageSpec(
            id: "r", name: "R", fileExtension: "R",
            keywords: words("if else repeat while function for in next break TRUE FALSE NULL Inf NaN NA library return"),
            lineComments: ["#"], stringDelimiters: ["\"", "'"], capitalizedAreTypes: false,
            runPlans: [[["Rscript", "{file}"]]]
        ),
        LanguageSpec(
            id: "sql", name: "SQL (SQLite)", fileExtension: "sql",
            keywords: words("select from where insert into values update set delete create table drop alter add primary key foreign references index view join left right inner outer on group by order having limit offset as and or not null is in like between distinct union all case when then else end begin commit rollback integer text real blob default unique"),
            lineComments: ["--"], blockComment: ["/*", "*/"], stringDelimiters: ["'", "\""], caseInsensitive: true, capitalizedAreTypes: false,
            runPlans: [[["sqlite3", "-header", "-column", ":memory:", ".read {file}"]]]
        ),
        LanguageSpec(
            id: "applescript", name: "AppleScript", fileExtension: "applescript",
            keywords: words("tell end if then else repeat with times while return set to of on display dialog activate application get copy the my it as try error considering ignoring"),
            lineComments: ["--", "#"], blockComment: ["(*", "*)"], stringDelimiters: ["\""], capitalizedAreTypes: false,
            runPlans: [[["osascript", "{file}"]]]
        ),
        LanguageSpec(
            id: "html", name: "HTML", fileExtension: "html", keywords: [],
            blockComment: ["<!--", "-->"], stringDelimiters: ["\"", "'"], capitalizedAreTypes: false,
            extraRules: [LanguageSpec.Rule(#"</?[A-Za-z][\w:-]*|/?>"#, .keyword), LanguageSpec.Rule(#"\b[\w:-]+(?==)"#, .attribute), LanguageSpec.Rule(#"&\w+;"#, .number)]
        ),
        LanguageSpec(
            id: "css", name: "CSS", fileExtension: "css", keywords: words("important media import from to"),
            blockComment: ["/*", "*/"], stringDelimiters: ["\"", "'"], capitalizedAreTypes: false,
            extraRules: [LanguageSpec.Rule(#"[\w-]+(?=\s*:[^:])"#, .attribute), LanguageSpec.Rule(#"#[0-9a-fA-F]{3,8}\b"#, .number), LanguageSpec.Rule(#"[.#][A-Za-z_][\w-]*(?=[^;{}]*\{)"#, .type)]
        ),
        LanguageSpec(
            id: "json", name: "JSON", fileExtension: "json", keywords: words("true false null"),
            stringDelimiters: ["\""], capitalizedAreTypes: false,
            extraRules: [LanguageSpec.Rule(#""(?:\\.|[^"\\])*"(?=\s*:)"#, .attribute, afterStrings: true)]
        ),
        LanguageSpec(
            id: "yaml", name: "YAML", fileExtension: "yaml", keywords: words("true false null yes no"),
            lineComments: ["#"], stringDelimiters: ["\"", "'"], capitalizedAreTypes: false,
            extraRules: [LanguageSpec.Rule(#"^\s*-?\s*[\w.-]+(?=\s*:)"#, .attribute)]
        ),
        LanguageSpec(
            id: "markdown", name: "Markdown", fileExtension: "md", keywords: [],
            stringDelimiters: [], capitalizedAreTypes: false,
            extraRules: [LanguageSpec.Rule(#"^#{1,6} .*$"#, .keyword), LanguageSpec.Rule(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, .type),
                         LanguageSpec.Rule(#"`[^`\n]+`"#, .string), LanguageSpec.Rule(#"\[[^\]\n]*\]\([^)\n]*\)"#, .function), LanguageSpec.Rule(#"^\s*([-*+]|\d+\.) "#, .attribute)]
        ),
    ]

    public static let runnable: [LanguageSpec] = all.filter(\.isRunnable)
}
