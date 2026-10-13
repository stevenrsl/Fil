import Foundation

/// Lecture d'une réponse `207 Multi-Status` à un `PROPFIND`.
enum WebDAVListing {
    static func parse(_ data: Data, rootPath: String, directory: RemotePath) throws -> [RemoteFile] {
        let collector = MultiStatusCollector()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        guard parser.parse() else {
            throw ProviderError.server("Le serveur a renvoyé une réponse WebDAV illisible.")
        }
        var seen = Set<RemotePath>()
        return collector.entries.compactMap { entry in
            guard let path = remotePath(forHref: entry.href, rootPath: rootPath),
                  path != directory, path.parent == directory, !path.isRoot,
                  seen.insert(path).inserted else { return nil }
            return RemoteFile(
                name: path.name,
                path: path,
                kind: entry.isCollection ? .directory : .file,
                byteCount: entry.isCollection ? nil : entry.length,
                modifiedAt: entry.modified
            )
        }
    }

    /// Première entrée d'une réponse `PROPFIND` de profondeur 0 : la ressource elle-même.
    static func parseEntry(_ data: Data) -> (length: Int64?, isCollection: Bool)? {
        let collector = MultiStatusCollector()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        guard parser.parse(), let first = collector.entries.first else { return nil }
        return (first.length, first.isCollection)
    }

    /// `href` absolu ou chemin seul, encodé ou non, ramené sous la racine WebDAV.
    static func remotePath(forHref href: String, rootPath: String) -> RemotePath? {
        var raw = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = raw.range(of: "://") {
            let afterScheme = raw[scheme.upperBound...]
            raw = afterScheme.firstIndex(of: "/").map { String(afterScheme[$0...]) } ?? "/"
        }
        if let cut = raw.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            raw = String(raw[..<cut])
        }
        let full = RemotePath(raw.removingPercentEncoding ?? raw)
        let root = RemotePath(rootPath)
        guard full.hasPrefix(root) else { return nil }
        return RemotePath(root.isRoot ? full.value : String(full.value.dropFirst(root.value.count)))
    }

    static func parseHTTPDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return ISO8601DateFormatter().date(from: value)
    }
}

private final class MultiStatusCollector: NSObject, XMLParserDelegate {
    struct Entry {
        var href = ""
        var isCollection = false
        var length: Int64?
        var modified: Date?
    }

    private(set) var entries: [Entry] = []
    private var current: Entry?
    private var propstat: Entry?
    private var propstatStatus: String?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch elementName.lowercased() {
        case "response":
            current = Entry()
        case "propstat":
            propstat = Entry()
            propstatStatus = nil
        case "collection":
            propstat?.isCollection = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case "href":
            if propstat == nil, current?.href.isEmpty == true { current?.href = value }
        case "status":
            if propstat != nil { propstatStatus = value }
        case "getcontentlength":
            propstat?.length = Int64(value)
        case "getlastmodified":
            propstat?.modified = WebDAVListing.parseHTTPDate(value)
        case "propstat":
            // Seules les propriétés trouvées (2xx) comptent ; les 404 sont des propriétés absentes.
            if let found = propstat, var entry = current, Self.isSuccess(propstatStatus) {
                entry.isCollection = entry.isCollection || found.isCollection
                entry.length = found.length ?? entry.length
                entry.modified = found.modified ?? entry.modified
                current = entry
            }
            propstat = nil
        case "response":
            if let current, !current.href.isEmpty { entries.append(current) }
            current = nil
        default:
            break
        }
        text = ""
    }

    /// `HTTP/1.1 200 OK` : le deuxième mot est le code. Sans statut, on fait confiance.
    private static func isSuccess(_ status: String?) -> Bool {
        guard let status else { return true }
        let words = status.split(separator: " ")
        return words.count >= 2 && words[1].hasPrefix("2")
    }
}
