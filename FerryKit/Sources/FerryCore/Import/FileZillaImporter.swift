import Foundation

/// Imports connections from a FileZilla **Site Manager** export
/// (`sitemanager.xml`; also the layout of the live `~/.config/filezilla/`
/// file). Read-only; Ferry never writes it. M20 checkpoint A, ADR-031.
///
/// Preserves the site-manager folder hierarchy: `<Folder>` blocks nest
/// `<Server>` and further `<Folder>` blocks, and each imported site carries its
/// ancestor folder names in `ImportedConnection.folderPath`.
///
/// **No secrets** (rule 6): the base64 `<Pass>` element is never read. Sites in
/// protocols Ferry can't speak (HTTP, S3, Storj, …) are skipped rather than
/// imported as something broken.
public enum FileZillaImporter {
    public static func parse(contentsOf url: URL) -> [ImportedConnection] {
        parse((try? Data(contentsOf: url)) ?? Data())
    }

    public static func parse(_ text: String) -> [ImportedConnection] {
        parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) -> [ImportedConnection] {
        guard !data.isEmpty else { return [] }
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.results
    }

    // MARK: Protocol mapping

    /// FileZilla's `ServerProtocol` enum → Ferry's scheme. Unknown/unsupported
    /// values (HTTP=2, S3, Storj, Dropbox, OneDrive, Google Cloud, …) return nil
    /// so the site is skipped.
    static func scheme(forProtocol raw: Int) -> TransferProtocol? {
        switch raw {
        case 0: return .ftp   // FTP (plain or, with the FTPS enum below, TLS)
        case 1: return .sftp  // SFTP
        case 3: return .ftps  // FTPS (implicit TLS)
        case 4: return .ftps  // FTPES (explicit TLS) — Ferry derives the mode from port
        default: return nil
        }
    }

    // MARK: - Event-based parsing

    /// Walks `<Servers>` → `<Folder>`/`<Server>` depth-first, accumulating the
    /// folder-name path. Folder names arrive as character data directly inside a
    /// `<Folder>` element (before its children), so we only route text to the
    /// folder-name buffer while a `<Folder>` is the innermost open element.
    private final class Delegate: NSObject, XMLParserDelegate {
        var results: [ImportedConnection] = []

        /// Open-element stack (to know whether text belongs to a folder name).
        private var elementStack: [String] = []
        /// One name buffer per open `<Folder>`, matching folder depth.
        private var folderNameBuffers: [String] = []

        /// Fields of the `<Server>` currently being read (nil ⇒ not in a server).
        private var server: [String: String]?
        /// The `<Server>` child element whose text we're currently collecting.
        private var currentField: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            elementStack.append(elementName)
            switch elementName {
            case "Folder":
                folderNameBuffers.append("")
            case "Server":
                server = [:]
                currentField = nil
            default:
                if server != nil { currentField = elementName; server?[elementName] = "" }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if let field = currentField, server != nil {
                server?[field, default: ""] += string
            } else if elementStack.last == "Folder", !folderNameBuffers.isEmpty {
                folderNameBuffers[folderNameBuffers.count - 1] += string
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            switch elementName {
            case "Server":
                if let server, let connection = build(server) { results.append(connection) }
                server = nil
                currentField = nil
            case "Folder":
                if !folderNameBuffers.isEmpty { folderNameBuffers.removeLast() }
            default:
                if server != nil, currentField == elementName { currentField = nil }
            }
            if elementStack.last == elementName { elementStack.removeLast() }
        }

        // MARK: Build

        private func build(_ fields: [String: String]) -> ImportedConnection? {
            func value(_ key: String) -> String? {
                fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            }
            guard let host = value("Host") else { return nil }
            let rawProtocol = Int(value("Protocol") ?? "") ?? 0
            guard let scheme = FileZillaImporter.scheme(forProtocol: rawProtocol) else { return nil }

            let port = Int(value("Port") ?? "") ?? scheme.defaultPort
            let name = value("Name") ?? host
            // Logontype 0 == anonymous; otherwise use the stored user, if any.
            let logontype = Int(value("Logontype") ?? "")
            let user = logontype == 0 ? "anonymous" : value("User")
            // Key auth only applies to SSH-based schemes. <Pass> is never read.
            let identityFile = scheme.usesSSH ? value("KeyFile") : nil

            let folderPath = folderNameBuffers
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            return ImportedConnection(name: name, scheme: scheme, host: host, port: port,
                                      user: user, identityFile: identityFile, folderPath: folderPath)
        }
    }
}

extension String {
    /// nil when the string is empty, else self — for terse optional-field reads.
    var nonEmpty: String? { isEmpty ? nil : self }
}
