import Darwin
import Foundation

/// How the app asks the run tool for what needs the token or the key. The run tool listens as
/// a launchd job (`Identity.helperLabel`) and takes a message only from the app, which macOS
/// checks by the code signature of whoever sends it. So the run tool is no way for another
/// program to the backups: started from a terminal, it has the owner confirm with Touch ID or
/// the password instead. So does the helper of a build no developer signed, where macOS has
/// no signature to check by; see `HelperConnection.checksCaller`.
@objc public protocol HelperProtocol {
    /// Runs one command of the run tool as if `arguments` were its command line, with `input`
    /// in the place of standard input. Answers with what the command prints, or with its
    /// error as a sentence.
    func call(_ arguments: [String], input: Data?, reply: @escaping (Data?, String?) -> Void)
}

public enum HelperConnection {
    /// Lets `connection` carry messages only to and from a program that the developer of this
    /// one signed as `identifier`; anyone else's are dropped by macOS. False when this program
    /// no longer matches its own signature: such a connection is not to be used. A build no
    /// developer signed has nobody to ask for and talks to anyone.
    public static func restrict(_ connection: NSXPCConnection, to identifier: String) -> Bool {
        switch Signature.own {
        case .team(let team):
            guard let requirement = Signature.requirementText(team: team, identifier: identifier) else { return false }
            connection.setCodeSigningRequirement(requirement)
            return true
        case .nobody:
            return true
        case .unknown:
            return false
        }
    }

    /// Whether macOS checks who is at the other end of a connection `restrict` let through,
    /// which it only does in a build a developer signed. Where it does not, any program of the
    /// user can connect, and whoever answers has to ask the owner in its place.
    public static var checksCaller: Bool { checksCaller(signedBy: Signature.own) }

    static func checksCaller(signedBy signer: Signature.Signer) -> Bool {
        if case .team = signer { return true }
        return false
    }
}

/// The programs the owner has confirmed over the helper of a build no developer signed. Such a
/// helper cannot tell who connects, so the owner confirms; asked once, they are not asked again
/// for the same running program, which is the app while its windows are in use. Another program
/// is another process and is asked about anew. A process is known by its id together with the
/// moment it began: the id alone is given to another program once this one has ended.
public struct ConfirmedCallers {
    private struct Process: Hashable { let pid: pid_t, seconds: UInt64, microseconds: UInt64 }
    private var confirmed: Set<Process> = []

    public init() {}

    private static func process(_ pid: pid_t) -> Process? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Process(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    public func holds(_ pid: pid_t) -> Bool {
        ConfirmedCallers.process(pid).map(confirmed.contains) ?? false
    }

    /// Notes the running program with this id as confirmed, and forgets those that have ended.
    public mutating func note(_ pid: pid_t) {
        confirmed = confirmed.filter { ConfirmedCallers.process($0.pid) == $0 }
        if let process = ConfirmedCallers.process(pid) { confirmed.insert(process) }
    }
}
