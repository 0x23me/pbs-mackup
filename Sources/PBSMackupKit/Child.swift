import Darwin
import Foundation

/// A program this one started, with `posix_spawn`. Not with Foundation's `Process`, for two
/// reasons. `Process` rewrites every argument into the form Foundation uses for file names, in
/// which an accent is a character of its own after its letter, and the client compares names
/// byte by byte. And `Process` can hand a program data on its standard input only.
///
/// Here arguments and environment arrive as they are given, byte for byte, and the program
/// can be given data on further descriptors. Of this program's other open descriptors, of the
/// signals it ignores and of those it blocks, the child gets none.
public final class Child {
    public let pid: pid_t
    /// What the program writes to its standard output, and with `mergingErrors` also what it
    /// writes to its standard error, in the order it writes them.
    public let output: FileHandle
    /// What the program writes to its standard error; nil with `mergingErrors`.
    public let errors: FileHandle?
    /// This side's ends of the input pipes, and what is still to be written to each.
    private var inputs: [(descriptor: Int32, data: Data)]
    private var status: Int32?
    private let lock = NSLock()

    /// Starts `executable`. Without an `environment` the program gets this one's. `input` is
    /// what it finds to read on its descriptors, by number; 0 is standard input, which is
    /// empty when nothing is given for it. With `sendingInput: false` nothing is written until
    /// `sendInput` is called, and a program that reads its input waits for that.
    public init(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                input: [Int32: Data] = [:], mergingErrors: Bool = false, sendingInput: Bool = true) throws {
        precondition(input.keys.allSatisfy { $0 == 0 || $0 > 2 }, "1 and 2 are the program's output")
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        var theirs: [Int32] = [], mine: [Int32] = []
        var started = false
        defer {
            posix_spawn_file_actions_destroy(&actions)
            theirs.forEach { close($0) }
            if !started { mine.forEach { close($0) } }
        }
        /// Makes a pipe, puts the child's end at `numbers` there and returns this side's end.
        func pipe(childReads: Bool, at numbers: [Int32]) throws -> Int32 {
            var ends: [Int32] = [0, 0]
            guard Darwin.pipe(&ends) == 0 else { throw Child.failure(executable, errno) }
            let own = ends[childReads ? 1 : 0]
            mine.append(own)
            _ = fcntl(own, F_SETFD, FD_CLOEXEC)
            // Writing to a program that has ended fails with an error, not with a signal that
            // would end this one.
            if childReads { _ = fcntl(own, F_SETNOSIGPIPE, 1) }
            // The child's end moves above every number that is given out, so that putting one
            // descriptor in its place never takes away another that is still to be placed.
            let end = fcntl(ends[childReads ? 0 : 1], F_DUPFD_CLOEXEC, max(3, (input.keys.max() ?? 0) + 1))
            close(ends[childReads ? 0 : 1])
            guard end >= 0 else { throw Child.failure(executable, errno) }
            theirs.append(end)
            for number in numbers { posix_spawn_file_actions_adddup2(&actions, end, number) }
            return own
        }
        if input[0] == nil { posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) }
        var inputs: [(descriptor: Int32, data: Data)] = []
        for (number, data) in input { inputs.append((try pipe(childReads: true, at: [number]), data)) }
        let out = try pipe(childReads: false, at: mergingErrors ? [1, 2] : [1])
        let err = mergingErrors ? nil : try pipe(childReads: false, at: [2])

        // Whatever else is open here is closed in the child. Every signal does there what it
        // does by default and none is blocked: this program may ignore the very signal a child
        // is to be stopped with. And the child is a process group of its own, as with
        // `Process`: Control-C in a terminal reaches this program alone, which stops its child.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                                                    | POSIX_SPAWN_SETPGROUP))

        // The bytes of the strings as they are: no form of writing an accent is turned into another.
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = (environment ?? ProcessInfo.processInfo.environment)
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard code == 0 else { throw Child.failure(executable, code) }
        started = true
        self.pid = pid
        self.inputs = inputs
        output = FileHandle(fileDescriptor: out, closeOnDealloc: true)
        errors = err.map { FileHandle(fileDescriptor: $0, closeOnDealloc: true) }
        if sendingInput { sendInput() }
    }

    private static func failure(_ executable: URL, _ code: Int32) -> Client.Failure {
        Client.Failure(description: "\(executable.path) could not be started: \(String(cString: strerror(code)))")
    }

    deinit { closeInput() }

    /// Writes each input and closes its descriptor.
    public func sendInput() { endInput(writing: true) }

    /// Closes the descriptors of the input without writing it: the program finds each of them empty.
    public func closeInput() { endInput(writing: false) }

    private func endInput(writing: Bool) {
        lock.lock()
        let pending = inputs
        inputs = []
        lock.unlock()
        for (descriptor, data) in pending {
            guard writing, !data.isEmpty else { close(descriptor); continue }
            // Each on a queue of its own: a program that writes before it reads would wait for
            // this side to read, while this side waited for it to read.
            DispatchQueue.global().async {
                data.withUnsafeBytes { bytes in
                    var sent = 0
                    while sent < bytes.count {
                        let count = write(descriptor, bytes.baseAddress! + sent, bytes.count - sent)
                        if count < 0 && errno == EINTR { continue }
                        // A program that ended, or closed the descriptor, without reading it all.
                        guard count > 0 else { break }
                        sent += count
                    }
                }
                close(descriptor)
            }
        }
    }

    /// The status the program ended with, or nil while it runs. Called with the lock held.
    /// Only here does the system get to forget a program that has ended and give its process
    /// id to another: as long as `status` is nil, `pid` is this program.
    private func ended(wait options: Int32) -> Int32? {
        if let status { return status }
        var raw: Int32 = 0
        var result = waitpid(pid, &raw, options)
        while result < 0 && errno == EINTR { result = waitpid(pid, &raw, options) }
        if result == 0 { return nil }
        // What `Process.terminationStatus` gave: the exit status, or the number of the signal
        // that ended the program, which is never 0.
        let signal = raw & 0x7f
        status = result < 0 ? -1 : signal == 0 ? (raw >> 8) & 0xff : signal
        return status
    }

    /// False once the program has ended.
    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return ended(wait: WNOHANG) == nil
    }

    /// Sends the program a signal, unless it has ended.
    public func signal(_ number: Int32) {
        lock.lock(); defer { lock.unlock() }
        if ended(wait: WNOHANG) == nil { kill(pid, number) }
    }

    /// Asks the program to stop, as Control-C does.
    public func interrupt() { signal(SIGINT) }

    /// Waits until the program has ended and returns its exit status; when a signal ended it,
    /// the number of the signal. So 0 only for a program that ended well.
    @discardableResult
    public func wait() -> Int32 {
        // Waits without the lock, so that `signal` can be called meanwhile, and without
        // letting the system forget the program, which is done with the lock in `ended`.
        var information = siginfo_t()
        while waitid(P_PID, id_t(pid), &information, WEXITED | WNOWAIT) != 0 && errno == EINTR {}
        lock.lock(); defer { lock.unlock() }
        return ended(wait: 0) ?? -1
    }

    /// Reads all the program writes, waits until it has ended and returns its exit status as
    /// `wait` does. Its standard error is read on another queue: a program that fills one
    /// pipe while this side reads the other would wait for ever.
    public func finish() -> (status: Int32, output: Data, errors: Data) {
        var data = Data()
        let result = finish { data.append($0) }
        return (result.status, data, result.errors)
    }

    /// As `finish`, but what the program writes to its standard output is handed to `take` as
    /// it arrives, a piece at a time, instead of being kept: for a program that writes a lot.
    public func finish(output take: (Data) -> Void) -> (status: Int32, errors: Data) {
        var complaints = Data()
        let group = DispatchGroup()
        if let errors { DispatchQueue.global().async(group: group) { complaints = errors.readDataToEndOfFile() } }
        while case let piece = output.availableData, !piece.isEmpty { take(piece) }
        group.wait()
        return (wait(), complaints)
    }
}
