import Foundation

/// How the app asks the run tool for what needs the token or the key. The run tool listens as
/// a launchd job (`Identity.helperLabel`) and takes a message only from the app, which macOS
/// checks by the code signature of whoever sends it. So the run tool is no way for another
/// program to the backups: started from a terminal, it has the owner confirm with Touch ID or
/// the password instead.
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
}
