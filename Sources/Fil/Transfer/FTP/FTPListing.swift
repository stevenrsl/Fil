import Foundation

/// Lecture des listings FTP : `MLSD` (RFC 3659) quand le serveur le connaît, `LIST` sinon.
enum FTPListing {
    static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: MLSD

    static func parseMLSD(_ text: String, in directory: RemotePath) -> [RemoteFile] {
        text.split(whereSeparator: \.isNewline).compactMap { parseMLSDLine(String($0), in: directory) }
    }

    static func parseMLSDLine(_ line: String, in directory: RemotePath) -> RemoteFile? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let name = String(line[line.index(after: space)...])
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }

        var facts: [String: String] = [:]
        for fact in line[..<space].split(separator: ";") {
            guard let equal = fact.firstIndex(of: "=") else { continue }
            facts[fact[..<equal].lowercased()] = String(fact[fact.index(after: equal)...])
        }
        let type = facts["type"]?.lowercased() ?? "file"
        let kind: RemoteFile.Kind
        var isLink = false
        switch type {
        case "cdir", "pdir": return nil
        case "dir": kind = .directory
        case "file": kind = .file
        default:
            if type.contains("slink") || type.contains("symlink") {
                kind = .link
                isLink = true
            } else {
                kind = .file
            }
        }
        let size = kind == .file ? facts["size"].flatMap { Int64($0) } : nil
        return RemoteFile(
            name: name,
            path: directory.appending(name),
            kind: kind,
            byteCount: size,
            modifiedAt: facts["modify"].flatMap(parseMLSDTime),
            isSymbolicLink: isLink
        )
    }

    /// `YYYYMMDDHHMMSS[.sss]`, toujours en UTC.
    static func parseMLSDTime(_ value: String) -> Date? {
        let digits = value.prefix(14)
        guard digits.count == 14, digits.allSatisfy(\.isNumber) else { return nil }
        func number(_ offset: Int, _ length: Int) -> Int {
            let start = digits.index(digits.startIndex, offsetBy: offset)
            return Int(digits[start..<digits.index(start, offsetBy: length)]) ?? 0
        }
        var components = DateComponents()
        components.year = number(0, 4)
        components.month = number(4, 2)
        components.day = number(6, 2)
        components.hour = number(8, 2)
        components.minute = number(10, 2)
        components.second = number(12, 2)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)
    }

    // MARK: LIST

    static func parseLIST(_ text: String, in directory: RemotePath, now: Date = .now, calendar: Calendar = .current) -> [RemoteFile] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = String(line)
            return parseUnixLine(line, in: directory, now: now, calendar: calendar)
                ?? parseDOSLine(line, in: directory)
        }
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// `drwxr-xr-x  2 user group  4096 Oct 12 15:30 nom avec espaces`
    static func parseUnixLine(_ line: String, in directory: RemotePath, now: Date, calendar: Calendar) -> RemoteFile? {
        guard let first = line.first, "-dlbcps".contains(first) else { return nil }

        var tokens: [Range<String.Index>] = []
        var index = line.startIndex
        while index < line.endIndex {
            while index < line.endIndex, line[index] == " " || line[index] == "\t" { index = line.index(after: index) }
            guard index < line.endIndex else { break }
            let start = index
            while index < line.endIndex, line[index] != " ", line[index] != "\t" { index = line.index(after: index) }
            tokens.append(start..<index)
        }
        guard tokens.count >= 6 else { return nil }

        // Le repère fiable est la date « Mois Jour Heure|Année », précédée de la taille.
        for monthIndex in 2..<(tokens.count - 2) {
            let monthToken = line[tokens[monthIndex]].lowercased()
            guard let month = months.firstIndex(of: String(monthToken.prefix(3))), monthToken.count <= 4,
                  let day = Int(line[tokens[monthIndex + 1]]), (1...31).contains(day),
                  let size = Int64(line[tokens[monthIndex - 1]]) else { continue }
            let timeOrYear = String(line[tokens[monthIndex + 2]])
            guard let modified = listDate(month: month + 1, day: day, timeOrYear: timeOrYear, now: now, calendar: calendar) else { continue }

            var name = String(line[tokens[monthIndex + 2].upperBound...])
            if name.hasPrefix(" ") { name.removeFirst() }
            let kind: RemoteFile.Kind
            switch first {
            case "d": kind = .directory
            case "l":
                kind = .link
                if let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            default: kind = .file
            }
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
            return RemoteFile(
                name: name,
                path: directory.appending(name),
                kind: kind,
                byteCount: kind == .file ? size : nil,
                modifiedAt: modified,
                isSymbolicLink: first == "l"
            )
        }
        return nil
    }

    private static func listDate(month: Int, day: Int, timeOrYear: String, now: Date, calendar: Calendar) -> Date? {
        var components = DateComponents(month: month, day: day)
        if timeOrYear.contains(":") {
            let parts = timeOrYear.split(separator: ":")
            guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
            components.hour = hour
            components.minute = minute
            // Sans année, la date est dans les douze derniers mois.
            components.year = calendar.component(.year, from: now)
            if let date = calendar.date(from: components), date > now.addingTimeInterval(86_400) {
                components.year! -= 1
            }
        } else {
            guard let year = Int(timeOrYear), (1970...9999).contains(year) else { return nil }
            components.year = year
        }
        return calendar.date(from: components)
    }

    /// Format IIS : `10-12-26  03:30PM       <DIR>          dossier`
    static func parseDOSLine(_ line: String, in directory: RemotePath) -> RemoteFile? {
        let pattern = /^(\d{2})-(\d{2})-(\d{2,4})\s+(\d{1,2}):(\d{2})\s*(AM|PM)?\s+(<DIR>|\d+)\s+(.+)$/
        guard let match = line.wholeMatch(of: pattern.ignoresCase()) else { return nil }
        let name = String(match.8)
        guard name != ".", name != "..", !name.contains("/") else { return nil }
        var year = Int(match.3) ?? 1970
        if year < 100 { year += year < 70 ? 2000 : 1900 }
        var hour = Int(match.4) ?? 0
        if let meridiem = match.6?.uppercased() {
            if meridiem == "PM", hour < 12 { hour += 12 }
            if meridiem == "AM", hour == 12 { hour = 0 }
        }
        let components = DateComponents(year: year, month: Int(match.1), day: Int(match.2), hour: hour, minute: Int(match.5))
        let isDirectory = match.7.uppercased() == "<DIR>"
        return RemoteFile(
            name: name,
            path: directory.appending(name),
            kind: isDirectory ? .directory : .file,
            byteCount: isDirectory ? nil : Int64(match.7),
            modifiedAt: Calendar.current.date(from: components)
        )
    }
}
