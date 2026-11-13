import Foundation
import Testing
@testable import PBSMackupKit

// How another program is started: what reaches it (arguments, environment, input on its
// descriptors) and what does not (anything else of this program's), how what it writes is read,
// and how it ends. The system's own tools stand in for the client.

private let shell = URL(fileURLWithPath: "/bin/sh")

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

@Test func argumentsAndEnvironmentArriveByteForByte() throws {
    // ü in one piece, and as u with ¨ after it: the same to the eye and to Swift, not the same bytes.
    let whole = "Z\u{FC}rich", apart = "Zu\u{308}rich"
    #expect(whole == apart && Array(whole.utf8) != Array(apart.utf8))
    for given in [whole, apart, "", "-x", "--", "two words", "a\nb", "$HOME *"] {
        let result = try Child(shell, ["-c", #"printf '%s' "$1"; printf '%s' "$NAME" >&2"#, "sh", given], environment: ["NAME": given]).finish()
        #expect(Array(result.output) == Array(given.utf8), "\(given)")
        #expect(Array(result.errors) == Array(given.utf8), "\(given)")
    }
    // An environment that is given is all the program gets; without one it gets this program's.
    let env = URL(fileURLWithPath: "/usr/bin/env")
    #expect(text(try Child(env, [], environment: ["A": "1", "B": "two words"]).finish().output).split(separator: "\n").sorted() == ["A=1", "B=two words"])
    #expect(text(try Child(env, []).finish().output).contains("PATH=\(ProcessInfo.processInfo.environment["PATH"] ?? "")\n"))
}

@Test func aChildFindsItsInputOnTheDescriptorsNamedAndNoOtherOpen() throws {
    // Something of this program's that a child would inherit as it is, under the lowest
    // number that is free here.
    let mine = open("/dev/null", O_RDONLY)
    defer { close(mine) }
    #expect(mine > 2 && fcntl(mine, F_GETFD) & FD_CLOEXEC == 0)
    // The shell tries the numbers below 10 and prints those it has open.
    let probe = #"exec 2>/dev/null; for n in 0 1 2 3 4 5 6 7 8 9; do (exec <&$n) && printf "$n "; done"#
    func openThere(with input: [Int32: Data]) throws -> String { text(try Child(shell, ["-c", probe], input: input).finish().output) }
    #expect(try openThere(with: [:]) == "0 1 2 ")
    #expect(try openThere(with: [0: Data("x".utf8), 4: Data("x".utf8), 9: Data("x".utf8)]) == "0 1 2 4 9 ")

    let read = try Child(shell, ["-c", "cat; cat <&3; cat <&7"], input: [0: Data("zero ".utf8), 3: Data("three ".utf8), 7: Data("seven".utf8)])
    #expect(text(read.finish().output) == "zero three seven")
    // Standard input that is not given is empty, not this program's.
    #expect(try Child(URL(fileURLWithPath: "/bin/cat"), []).finish().output.isEmpty)
}

@Test func inputIsHeldBackUntilItIsSent() throws {
    let cat = URL(fileURLWithPath: "/bin/cat")
    let held = try Child(cat, [], input: [0: Data("the key".utf8)], sendingInput: false)
    usleep(200_000)
    #expect(held.isRunning)                             // it waits for its input,
    held.sendInput()
    #expect(text(held.finish().output) == "the key")    // and gets it when it is sent,
    let refused = try Child(cat, [], input: [0: Data("the key".utf8)], sendingInput: false)
    refused.closeInput()
    let result = refused.finish()
    #expect(result.status == 0 && result.output.isEmpty)        // or nothing at all
}

@Test func aChildOfAParentThatIgnoresASignalStillEndsOnIt() throws {
    // As the run tool does with the signals it turns into a cancelled run: it ignores them
    // itself. A child that inherited that could not be stopped with them. Blocked signals are
    // inherited the same way.
    let before = Darwin.signal(SIGINT, SIG_IGN)
    defer { _ = Darwin.signal(SIGINT, before) }
    var blocked = sigset_t(), earlier = sigset_t()
    sigemptyset(&blocked)
    sigaddset(&blocked, SIGTERM)
    pthread_sigmask(SIG_BLOCK, &blocked, &earlier)
    defer { pthread_sigmask(SIG_SETMASK, &earlier, nil) }

    let sleep = URL(fileURLWithPath: "/bin/sleep"), started = Date()
    let interrupted = try Child(sleep, ["30"])
    #expect(interrupted.isRunning)
    interrupted.interrupt()
    #expect(interrupted.wait() == SIGINT)               // ended by the signal, and the status says so
    #expect(!interrupted.isRunning)
    let terminated = try Child(sleep, ["30"])
    terminated.signal(SIGTERM)
    #expect(terminated.wait() == SIGTERM)
    #expect(Date().timeIntervalSince(started) < 10)     // and not by its 30 seconds running out
}

@Test func aChildThatWritesMuchAndReadsNothingIsReadToItsEnd() throws {
    // More than a pipe holds, to standard error first: read one after the other, the two
    // programs would wait for each other for ever. The same for input the program never reads.
    let much = Data(repeating: 0x61, count: 1_000_000)
    let result = try Child(shell, ["-c", "head -c 1000000 /dev/zero >&2; head -c 1000000 /dev/zero; exit 3"], input: [0: much, 3: much]).finish()
    #expect(result.status == 3 && result.output.count == much.count && result.errors.count == much.count)
    // One that ends at once: what is written to it goes nowhere, and does not end this
    // program with the signal for a pipe nobody reads.
    #expect(try Child(URL(fileURLWithPath: "/usr/bin/true"), [], input: [0: much, 3: much]).finish().status == 0)
    // One that reads it all gets it all.
    #expect(try Child(URL(fileURLWithPath: "/bin/cat"), [], input: [0: much]).finish().output == much)
}

@Test func theStatusSaysHowAChildEnded() throws {
    #expect(try Child(shell, ["-c", "exit 0"]).wait() == 0)
    #expect(try Child(shell, ["-c", "exit 7"]).wait() == 7)
    #expect(try Child(shell, ["-c", "kill -KILL $$"]).wait() == SIGKILL)
    // Its process id is the one it has, and it leads a process group of its own.
    let child = try Child(shell, ["-c", "echo $$; ps -o pgid= -p $$"])
    let numbers = text(child.finish().output).split(separator: "\n").map { Int32($0.trimmingCharacters(in: .whitespaces)) }
    #expect(numbers == [child.pid, child.pid])
    #expect(child.wait() == 0)                          // asked again, the same answer

    // Both outputs through one pipe, in the order they were written, the last line without its end.
    let merged = try Child(shell, ["-c", "echo out; echo err >&2; printf last"], mergingErrors: true)
    #expect(merged.errors == nil)
    #expect(text(merged.finish().output) == "out\nerr\nlast")

    // A program that is not there is an error that names it.
    let missing = "/nonexistent/program could not be started: No such file or directory"
    do {
        _ = try Child(URL(fileURLWithPath: "/nonexistent/program"), [])
        Issue.record("started a program that is not there")
    } catch { #expect("\(error)" == missing) }

    // A system tool: both outputs together, nothing to read, and the same error.
    #expect(tool("/bin/sh", ["-c", "echo out; echo err >&2; cat; exit 4"]) == (4, "out\nerr"))
    #expect(tool("/nonexistent/program", []) == (-1, missing))
}
