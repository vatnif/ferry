import Foundation
@testable import FerryCore

enum TestFixtures {
    /// Whole-second date: the store persists ISO8601 without fractional
    /// seconds, so fixtures avoid sub-second parts to keep round-trip
    /// equality exact.
    static let date = Date(timeIntervalSince1970: 1_750_000_000)

    static func profile(name: String,
                        scheme: TransferProtocol = .sftp,
                        authMethod: AuthenticationMethod = .password) -> ConnectionProfile {
        ConnectionProfile(name: name,
                          scheme: scheme,
                          host: "example.com",
                          username: "deploy",
                          authMethod: authMethod,
                          createdAt: date,
                          modifiedAt: date)
    }

    /// The tree from mockup screen 1:
    /// Work[prod-web-01, staging], Clients[acme[db-bastion]], loose pi-home
    static func library() -> (library: ConnectionLibrary,
                              work: ProfileFolder, clients: ProfileFolder, acme: ProfileFolder,
                              prod: ConnectionProfile, staging: ConnectionProfile,
                              bastion: ConnectionProfile, pi: ConnectionProfile) {
        let prod = profile(name: "prod-web-01")
        let staging = profile(name: "staging")
        let bastion = profile(name: "db-bastion")
        let pi = profile(name: "pi-home")
        let acme = ProfileFolder(name: "acme", items: [.profile(bastion)])
        let work = ProfileFolder(name: "Work", items: [.profile(prod), .profile(staging)])
        let clients = ProfileFolder(name: "Clients", items: [.folder(acme)])
        let library = ConnectionLibrary(items: [.folder(work), .folder(clients), .profile(pi)])
        return (library, work, clients, acme, prod, staging, bastion, pi)
    }
}
