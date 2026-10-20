import Darwin
import Foundation
import FolioTerminal

/// A program with a controlling pseudo terminal: interactive shells and Ctrl-C work as in Terminal.app.
public final class PseudoTerminal: @unchecked Sendable {
    private let master: FileHandle
    private let lock = NSLock()
    private var exited = false
    public var onOutput: (@Sendable (String) -> Void)?
    public var onExit: (@Sendable (Int32) -> Void)?
    public let pid: pid_t
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return !exited }

    public enum TerminalError: LocalizedError {
        case pty
        public var errorDescription: String? { "Es konnte kein Terminal angelegt werden." }
    }

    public init(command: [String]? = nil, directory: URL? = nil, environment: [String: String] = InterpreterLocator.shared.environment,
                columns: Int = 100, rows: Int = 30) throws {
        let shell = environment["SHELL"] ?? "/bin/zsh"
        let cmd = command ?? [shell, "-l"]
        guard !cmd.isEmpty else { throw TerminalError.pty }
        var env = environment
        // The panel displays plain text, not a cursor-addressable terminal emulator.
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        let argv = cmd.map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var fd: Int32 = -1
        let cwd = (directory ?? FileManager.default.homeDirectoryForCurrentUser).path
        let child = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { vars in
                cwd.withCString { path in
                    folio_spawn_terminal(&fd, args.baseAddress, vars.baseAddress, path,
                                         UInt16(clamping: columns), UInt16(clamping: rows))
                }
            }
        }
        guard child > 0 else { throw TerminalError.pty }
        pid = child
        master = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        master.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            self?.onOutput?(String(decoding: data, as: UTF8.self))
        }
        DispatchQueue.global().async { [weak self] in
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            guard let self else { return }
            self.lock.lock(); self.exited = true; self.lock.unlock()
            let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            self.onExit?(code)
        }
    }

    deinit { terminate() }

    public func send(_ text: String) {
        guard isRunning else { return }
        try? master.write(contentsOf: Data(text.utf8))
    }

    public func interrupt() { send("\u{03}") }
    public func endOfInput() { send("\u{04}") }

    public func resize(columns: Int, rows: Int) {
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master.fileDescriptor, TIOCSWINSZ, &size)
    }

    public func terminate() {
        master.readabilityHandler = nil
        if isRunning { ServerDetector.terminateTree(pid) }
    }
}
