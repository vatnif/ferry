import Foundation
import NIOSSH

/// Ferry's own host-key store — the trust anchor for TOFU (DOMAIN.md → Host
/// key trust). Persisted as an OpenSSH-format `known_hosts` file at
/// `~/Library/Application Support/Ferry/known_hosts`. Ferry only ever writes
/// **plaintext** host entries here; the user's `~/.ssh/known_hosts` is read
/// separately (M11 checkpoint B) and never written.
///
/// Stateless persister (mirrors ConnectionStore): the file is the single
/// source of truth, so trust decisions made in one place are seen everywhere.
/// Entries are keyed by `host` (port 22) or `[host]:port` (non-default port),
/// matching the OpenSSH convention.
public struct HostKeyStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Production location, alongside connections.json (inside the container
    /// when sandboxed — correct in both distributions).
    public static func `default`() throws -> HostKeyStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil,
                                                  create: true)
        return HostKeyStore(fileURL: support
            .appendingPathComponent("Ferry", isDirectory: true)
            .appendingPathComponent("known_hosts"))
    }

    // MARK: Reads (internal — used by SFTPSource's TOFU flow)

    /// The set of keys Ferry already trusts for this endpoint. Empty ⇒ first
    /// contact (unknown host); non-empty but not containing the offered key ⇒
    /// the key has CHANGED.
    func trustedKeys(host: String, port: Int) throws -> Set<NIOSSHPublicKey> {
        let spec = Self.hostSpec(host: host, port: port)
        var keys = Set<NIOSSHPublicKey>()
        for entry in try entries() where entry.matches(spec) {
            if let key = try? NIOSSHPublicKey(openSSHPublicKey: entry.openSSH) {
                keys.insert(key)
            }
        }
        return keys
    }

    // MARK: Reads (public — for the changed-key dialog)

    /// Fingerprints Ferry currently trusts for this endpoint, for display in
    /// the "was → now" comparison of the changed-key alarm.
    public func storedInfos(host: String, port: Int) throws -> [HostKeyInfo] {
        let spec = Self.hostSpec(host: host, port: port)
        return try entries()
            .filter { $0.matches(spec) }
            .compactMap { HostKeyInfo(openSSHLine: $0.openSSH) }
    }

    public func contains(host: String, port: Int) throws -> Bool {
        try !storedInfos(host: host, port: port).isEmpty
    }

    // MARK: Writes (public — driven by the user's trust decisions)

    /// Records a newly trusted key for the endpoint (TOFU "Trust & Connect").
    /// Idempotent: an identical entry is not duplicated.
    public func trust(_ info: HostKeyInfo, host: String, port: Int) throws {
        let spec = Self.hostSpec(host: host, port: port)
        var lines = try existingLines()
        let newLine = "\(spec) \(info.openSSH)"
        guard !lines.contains(newLine) else { return }
        lines.append(newLine)
        try write(lines)
    }

    /// Replaces every stored key for the endpoint with `info` (changed-key
    /// alarm → "Replace Key & Connect"). No silent path reaches here — the UI
    /// gates it behind a second confirmation.
    public func replace(with info: HostKeyInfo, host: String, port: Int) throws {
        try remove(host: host, port: port)
        try trust(info, host: host, port: port)
    }

    /// Drops all trusted keys for the endpoint.
    public func remove(host: String, port: Int) throws {
        let spec = Self.hostSpec(host: host, port: port)
        let kept = try entries().filter { !$0.matches(spec) }.map(\.rawLine)
        try write(kept)
    }

    // MARK: File IO

    private func existingLines() throws -> [String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func entries() throws -> [Entry] {
        try existingLines().compactMap(Entry.init(rawLine:))
    }

    private func write(_ lines: [String]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Keep exactly the non-empty lines, one per entry, trailing newline.
        let body = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
        let output = body.isEmpty ? "" : body + "\n"
        try output.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: Line model

    /// One parsed `known_hosts` line: `<hostspec[,hostspec…]> <keytype> <base64>`.
    /// Ferry writes single, plaintext host specs; parsing tolerates a
    /// comma-separated list (as OpenSSH allows) so re-reads stay robust.
    private struct Entry {
        let rawLine: String
        let hostSpecs: [String]
        let openSSH: String // "<keytype> <base64>"

        init?(rawLine: String) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, !fields[0].hasPrefix("@") else { return nil }
            self.rawLine = trimmed
            self.hostSpecs = fields[0].split(separator: ",").map { $0.lowercased() }
            self.openSSH = "\(fields[1]) \(fields[2])"
        }

        func matches(_ spec: String) -> Bool {
            hostSpecs.contains(spec.lowercased())
        }
    }

    /// OpenSSH host-spec convention: bare host for port 22, `[host]:port`
    /// otherwise.
    static func hostSpec(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }
}
