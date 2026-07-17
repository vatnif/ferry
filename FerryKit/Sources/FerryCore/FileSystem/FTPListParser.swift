import Foundation

/// Parses the Unix `ls -l`-style output of an FTP `LIST` command into
/// `FileItem`s. This is the classic fragile seam of any FTP client: unlike
/// SFTP there is no structured attribute record — libcurl hands back whatever
/// text the server's `LIST` produced, and the de-facto standard is BSD/GNU
/// `ls -l` (what vsftpd, proftpd, pure-ftpd emit). Ferry parses that dialect.
///
/// Deliberately best-effort on the date: `LIST` timestamps are in the server's
/// local time zone, at minute (recent) or year (old) resolution, with no offset
/// — so `modifiedAt` is approximate and may be nil when unparseable. Precise
/// times would need a per-file `MDTM` round-trip (backlog). Non-Unix listings
/// (raw MS-DOS `MM-DD-YY` format) are not parsed — the servers Ferry targets
/// emit Unix listings; ADR-019.
enum FTPListParser {
    /// Parses a full multi-line `LIST` body. `directory` is the absolute path
    /// that was listed (used to build each item's full path). `now`/`timeZone`
    /// pin the year inference for time-only dates (tests inject them).
    static func parse(_ listing: String,
                      directory: String,
                      now: Date = Date(),
                      timeZone: TimeZone = .current) -> [FileItem] {
        listing
            .split(whereSeparator: \.isNewline)
            .compactMap { parseLine(String($0), directory: directory, now: now, timeZone: timeZone) }
    }

    /// Parses a single listing line, or returns nil for lines that aren't file
    /// entries (`total N` headers, `.`/`..`, blanks, unparseable rows).
    static func parseLine(_ rawLine: String,
                          directory: String,
                          now: Date = Date(),
                          timeZone: TimeZone = .current) -> FileItem? {
        // FTP sends CRLF; strip a trailing CR and surrounding whitespace.
        let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        guard !line.isEmpty else { return nil }
        if line.hasPrefix("total ") { return nil }

        // Split off the 8 fixed leading fields; the name is everything after,
        // so names containing spaces survive intact.
        guard let (fields, nameField) = splitLeadingFields(line, count: 8),
              fields.count == 8 else { return nil }

        let permissionString = fields[0]
        guard permissionString.count >= 10 else { return nil }
        let typeChar = permissionString.first!
        guard let parsed = parseMode(permissionString) else { return nil }

        let isDirectory = typeChar == "d"
        let isSymlink = typeChar == "l"

        // Symlinks list as "name -> target"; keep the link's own name.
        var name = nameField
        if isSymlink, let arrow = nameField.range(of: " -> ") {
            name = String(nameField[nameField.startIndex..<arrow.lowerBound])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        let size = Int64(fields[4])
        let modified = parseDate(month: fields[5], day: fields[6], timeOrYear: fields[7],
                                 now: now, timeZone: timeZone)

        return FileItem(name: name,
                        path: join(directory, name),
                        isDirectory: isDirectory,
                        isSymlink: isSymlink,
                        isHidden: name.hasPrefix("."),
                        size: isDirectory ? nil : size,
                        modifiedAt: modified,
                        permissions: FilePermissions(rawMode: parsed),
                        owner: fields[2],
                        group: fields[3])
    }

    // MARK: - Field splitting

    /// Returns the first `count` whitespace-delimited fields plus the remainder
    /// of the line (the file name, with internal spaces preserved). Nil if the
    /// line has fewer than `count` fields.
    private static func splitLeadingFields(_ line: String, count: Int) -> ([String], String)? {
        var fields: [String] = []
        var index = line.startIndex
        let end = line.endIndex

        while fields.count < count {
            // Skip leading whitespace.
            while index < end, line[index] == " " || line[index] == "\t" { index = line.index(after: index) }
            guard index < end else { return nil }
            let fieldStart = index
            while index < end, line[index] != " ", line[index] != "\t" { index = line.index(after: index) }
            fields.append(String(line[fieldStart..<index]))
        }
        // Skip whitespace before the name.
        while index < end, line[index] == " " || line[index] == "\t" { index = line.index(after: index) }
        return (fields, String(line[index..<end]))
    }

    // MARK: - Mode

    /// Converts a 10-char `ls` permission string ("drwxr-sr-t") into the lower
    /// 12 POSIX mode bits (rwx + setuid/setgid/sticky).
    private static func parseMode(_ string: String) -> UInt16? {
        let chars = Array(string)
        guard chars.count >= 10 else { return nil }
        var mode: UInt16 = 0

        func rwx(_ r: Int, _ w: Int, _ x: Int, base: UInt16) {
            if chars[r] == "r" { mode |= base << 2 }
            if chars[w] == "w" { mode |= base << 1 }
            // Execute column doubles as the special-bit indicator:
            // x/s/t → executable set; s/S (setuid/setgid) and t/T (sticky).
            if chars[x] == "x" || chars[x] == "s" || chars[x] == "t" { mode |= base }
        }
        rwx(1, 2, 3, base: 0o100)   // user
        rwx(4, 5, 6, base: 0o010)   // group
        rwx(7, 8, 9, base: 0o001)   // other

        if chars[3] == "s" || chars[3] == "S" { mode |= 0o4000 }   // setuid
        if chars[6] == "s" || chars[6] == "S" { mode |= 0o2000 }   // setgid
        if chars[9] == "t" || chars[9] == "T" { mode |= 0o1000 }   // sticky
        return mode
    }

    // MARK: - Date

    private static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
    ]

    /// Best-effort reconstruction of a `ls`-style date. `timeOrYear` is either
    /// "HH:mm" (recent — infer the year) or "YYYY" (older files).
    private static func parseDate(month: String, day: String, timeOrYear: String,
                                  now: Date, timeZone: TimeZone) -> Date? {
        guard let monthNumber = months[month.lowercased()],
              let dayNumber = Int(day) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.month = monthNumber
        components.day = dayNumber

        if timeOrYear.contains(":") {
            let parts = timeOrYear.split(separator: ":")
            guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
            components.hour = hour
            components.minute = minute
            // No year in the listing: assume the current one, but if that lands
            // in the future (e.g. "Dec 31 23:59" seen in January) it must be
            // last year — the standard `ls` heuristic.
            let currentYear = calendar.component(.year, from: now)
            components.year = currentYear
            if let candidate = calendar.date(from: components), candidate > now.addingTimeInterval(86_400) {
                components.year = currentYear - 1
            }
        } else {
            guard let year = Int(timeOrYear) else { return nil }
            components.year = year
        }
        return calendar.date(from: components)
    }

    private static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}
