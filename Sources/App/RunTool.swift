import Foundation
import PBSMackupKit

/// The app asks pbs-mackup-run for everything that needs the token or the key: the run tool owns
/// the Keychain items, so the app itself never reads them. It asks over the connection of the
/// helper job, where macOS checks both ends by their signature: the run tool takes messages only
/// from this app, and the app talks only to its own developer's run tool.
enum RunTool {
    /// Has the run tool do `arguments`, one of its commands, optionally with data in the place
    /// of its standard input, and returns what it made. Throws with its error when it fails.
    static func call(_ arguments: [String], input: Data? = nil) async throws -> Data {
        #if DEBUG
        try await start(arguments, input: input)
        #else
        try await ask(arguments, input: input)
        #endif
    }

    static func decode<T: Decodable>(_ type: T.Type, _ arguments: [String], input: Data? = nil) async throws -> T {
        try JSONDecoder.iso8601.decode(type, from: try await call(arguments, input: input))
    }

    /// Resumes whoever waits for the run tool, once: an answer and the end of the connection can both arrive.
    private final class Answer: @unchecked Sendable {
        private var waiting: CheckedContinuation<Data, Error>?
        private let lock = NSLock()

        init(_ waiting: CheckedContinuation<Data, Error>) { self.waiting = waiting }

        func give(_ result: Result<Data, Error>) {
            lock.lock()
            let waiting = self.waiting
            self.waiting = nil
            lock.unlock()
            waiting?.resume(with: result)
        }
    }

    private static func ask(_ arguments: [String], input: Data?) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let answer = Answer(continuation)
            let connection = NSXPCConnection(machServiceName: Identity.helperLabel)
            connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            guard HelperConnection.restrict(connection, to: Identity.toolIdentifier) else {
                return answer.give(.failure(Failure(description: "This app no longer matches its own signature. Install it again.")))
            }
            connection.resume()
            let helper = connection.remoteObjectProxyWithErrorHandler { error in
                answer.give(.failure(Failure(description: "The run tool did not answer: \(error.localizedDescription)")))
                connection.invalidate()
            } as? HelperProtocol
            guard let helper else {
                connection.invalidate()
                return answer.give(.failure(Failure(description: "The run tool cannot be asked.")))
            }
            helper.call(arguments, input: input) { data, error in
                if let data { answer.give(.success(data)) }
                else { answer.give(.failure(Failure(description: error ?? "The run tool gave no answer."))) }
                connection.invalidate()
            }
        }
    }

    /// A development build has no helper job: it starts the run tool as a program, and says so
    /// that the tool does not ask to confirm what the app asks for. Only a development build of
    /// the tool listens to that.
    private static func start(_ arguments: [String], input: Data?) async throws -> Data {
        guard let tool = Bundle.main.url(forAuxiliaryExecutable: "pbs-mackup-run") else {
            throw Failure(description: "pbs-mackup-run is missing from the app.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Not with `Process`: that would hand over a path from the Backups window with
                // its accents written another way, and the client would not find it.
                do {
                    let environment = ProcessInfo.processInfo.environment.merging(["PBS_MACKUP_APP": "1"]) { $1 }
                    let result = try Child(tool, arguments, environment: environment, input: input.map { [0: $0] } ?? [:]).finish()
                    if result.status == 0 { continuation.resume(returning: result.output) }
                    else {
                        let text = String(decoding: result.errors.isEmpty ? result.output : result.errors, as: UTF8.self)
                        continuation.resume(throwing: Failure(description: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
