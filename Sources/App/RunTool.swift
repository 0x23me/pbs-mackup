import Foundation
import PBSMackupKit

/// The app asks pbs-mackup-run for everything that needs the token or the key: the run tool owns
/// the Keychain items, so the app itself never reads them.
enum RunTool {
    /// Runs `pbs-mackup-run` with `arguments`, optionally with data on standard input, and returns
    /// what it printed. Throws with what it wrote to standard error when it fails.
    static func call(_ arguments: [String], input: Data? = nil) async throws -> Data {
        guard let tool = Bundle.main.url(forAuxiliaryExecutable: "pbs-mackup-run") else {
            throw Client.Failure(description: "pbs-mackup-run is missing from the app.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(), out = Pipe(), err = Pipe(), stdin = Pipe()
                process.executableURL = tool
                process.arguments = arguments
                process.standardOutput = out
                process.standardError = err
                process.standardInput = stdin
                do { try process.run() } catch { continuation.resume(throwing: error); return }
                if let input { stdin.fileHandleForWriting.write(input) }
                try? stdin.fileHandleForWriting.close()
                var errors = Data()
                let group = DispatchGroup()
                DispatchQueue.global().async(group: group) { errors = err.fileHandleForReading.readDataToEndOfFile() }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                if process.terminationStatus == 0 { continuation.resume(returning: data) }
                else {
                    let text = String(decoding: errors.isEmpty ? data : errors, as: UTF8.self)
                    continuation.resume(throwing: Client.Failure(description: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ arguments: [String], input: Data? = nil) async throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: try await call(arguments, input: input))
    }
}
