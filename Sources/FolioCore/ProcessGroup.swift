import Foundation

#if os(macOS)
    import Darwin

    /// Who a process is: its pid and when it started. A pid alone may already belong to another program when a delayed
    /// signal is sent (#288).
    public struct ProcessIdentity: Hashable, Sendable {
        public let pid: pid_t
        public let started: UInt64

        /// The identity of a running process, nil when it is gone.
        public static func of(_ pid: pid_t) -> ProcessIdentity? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return ProcessIdentity(pid: pid, started: UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec))
        }

        /// Still the same process (not ended, pid not reused).
        public var isAlive: Bool { Self.of(pid) == self }

        /// Sends `signal` only if the pid still belongs to this process.
        @discardableResult
        public func signal(_ signal: Int32) -> Bool { isAlive && kill(pid, signal) == 0 }
    }

    /// A child process in a process group of its own, started with `posix_spawn`. Everything it starts stays in that
    /// group (unless it detaches on purpose), so stopping the group also catches short-lived helpers and orphans that
    /// polling would miss (#287, #289). Only the pipes passed in are inherited; no other file of Folio's.
    final class GroupProcess: @unchecked Sendable {
        let pid: pid_t
        let identity: ProcessIdentity?
        private let lock = NSLock()
        private var status: Int32?
        private var exitHandlers: [(Int32) -> Void] = []
        private var source: DispatchSourceProcess?

        /// `stdin`, `stdout`, `stderr` are file descriptors for the child (they are duplicated, the caller closes its copies).
        init(executable: String, arguments: [String], directory: URL, environment: [String: String], stdin: Int32, stdout: Int32, stderr: Int32) throws {
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_adddup2(&actions, stdin, 0)
            posix_spawn_file_actions_adddup2(&actions, stdout, 1)
            posix_spawn_file_actions_adddup2(&actions, stderr, 2)
            posix_spawn_file_actions_addchdir_np(&actions, directory.path)
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            // Own process group; no inherited descriptors besides 0, 1, 2; default signal handling and mask.
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
            posix_spawnattr_setpgroup(&attributes, 0)
            var all = sigset_t()
            sigfillset(&all)
            posix_spawnattr_setsigdefault(&attributes, &all)
            var none = sigset_t()
            sigemptyset(&none)
            posix_spawnattr_setsigmask(&attributes, &none)
            let argv = ([executable] + arguments).map { strdup($0) } + [nil]
            let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer {
                argv.forEach { free($0) }
                envp.forEach { free($0) }
            }
            var child: pid_t = 0
            let result = posix_spawn(&child, executable, &actions, &attributes, argv, envp)
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
            pid = child
            identity = ProcessIdentity.of(child)
            let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .global())
            source.setEventHandler { [weak self] in self?.reap() }
            self.source = source
            source.resume()
            reap(blocking: false)
        }

        deinit { source?.cancel() }

        var isRunning: Bool {
            lock.lock()
            defer { lock.unlock() }
            return status == nil
        }

        /// Exit code, or the signal number for a process that was killed (like `Process.terminationStatus`).
        var terminationStatus: Int32 {
            lock.lock()
            defer { lock.unlock() }
            return status ?? 0
        }

        /// Called once, when the process has ended (right away if it already has).
        func onExit(_ handler: @escaping (Int32) -> Void) {
            lock.lock()
            if let status {
                lock.unlock()
                handler(status)
                return
            }
            exitHandlers.append(handler)
            lock.unlock()
        }

        private func reap(blocking: Bool = true) {
            var raw: Int32 = 0
            let r = waitpid(pid, &raw, blocking ? 0 : WNOHANG)
            guard r == pid else { return }
            let code: Int32 = (raw & 0x7F) == 0 ? (raw >> 8) & 0xFF : raw & 0x7F
            lock.lock()
            guard status == nil else {
                lock.unlock()
                return
            }
            status = code
            let handlers = exitHandlers
            exitHandlers = []
            lock.unlock()
            source?.cancel()
            handlers.forEach { $0(code) }
        }

        /// Signals the whole group. The group id is the leader's pid; it cannot be handed to another process while any
        /// member of the group lives, and after that the call finds no group (#288).
        @discardableResult
        func signalGroup(_ signal: Int32) -> Bool { killpg(pid, signal) == 0 }

        /// Whether any process of the group is still alive.
        var groupIsAlive: Bool { killpg(pid, 0) == 0 }
    }

    /// Reads what is left in a pipe without ever blocking for long: a background process that inherited the pipe and
    /// keeps it open must not hang the run (#287).
    func drainBounded(_ handle: FileHandle, timeout: TimeInterval = 1) -> Data {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                out.append(buffer, count: n)
            } else if n == 0 {
                break
            } else if errno == EAGAIN || errno == EINTR {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&p, 1, 20)
            } else {
                break
            }
        }
        return out
    }
#endif
