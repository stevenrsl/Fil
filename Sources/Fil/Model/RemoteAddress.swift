import Foundation

/// Ce qu'on peut tirer d'une adresse collée telle quelle : `sftp://moi@exemple.fr:2222/www`,
/// `moi@exemple.fr`, `exemple.fr:2121`, `https://cloud.exemple.fr/remote.php/dav/files/moi`.
public struct RemoteAddress: Equatable, Sendable {
    public var `protocol`: RemoteProtocol?
    public var host: String
    public var port: Int?
    public var username: String?
    public var path: String?

    public init(protocol: RemoteProtocol? = nil, host: String, port: Int? = nil, username: String? = nil, path: String? = nil) {
        self.protocol = `protocol`
        self.host = host
        self.port = port
        self.username = username
        self.path = path
    }

    /// `nil` quand la saisie est déjà un simple nom d'hôte : rien à répartir.
    public init?(parsing input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let schemeEnd = text.range(of: "://") {
            let scheme = text[..<schemeEnd.lowerBound].lowercased()
            guard let components = URLComponents(string: text), let host = components.host, !host.isEmpty else { return nil }
            var proto: RemoteProtocol?
            switch scheme {
            case "ftp": proto = .ftp
            case "ftps", "ftpes": proto = .ftps
            case "sftp", "ssh", "scp": proto = .sftp
            case "http", "https", "dav", "davs", "webdav", "webdavs":
                proto = host.lowercased().hasSuffix("kdrive.infomaniak.com") ? .kdrive : .webdav
            default: return nil
            }
            self.protocol = proto
            self.host = host
            self.port = components.port
            if let port = components.port, port == 990, proto == .ftps {
                self.port = 990
            }
            self.username = components.user?.removingPercentEncoding ?? components.user
            let path = components.percentEncodedPath.removingPercentEncoding ?? components.path
            self.path = (path.isEmpty || path == "/") ? nil : path
            return
        }

        var rest = Substring(text)
        var username: String?
        if let at = rest.lastIndex(of: "@") {
            username = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
        }
        var path: String?
        if let slash = rest.firstIndex(of: "/") {
            path = String(rest[slash...])
            rest = rest[..<slash]
        }
        var port: Int?
        let colons = rest.filter { $0 == ":" }.count
        if colons == 1, let colon = rest.firstIndex(of: ":") {
            port = Int(rest[rest.index(after: colon)...])
            rest = rest[..<colon]
        }
        guard username != nil || path != nil || port != nil, !rest.isEmpty else { return nil }
        self.protocol = nil
        self.host = String(rest)
        self.port = port
        self.username = (username?.isEmpty ?? true) ? nil : username
        self.path = (path == "/") ? nil : path
    }
}

extension RemoteConnection {
    /// Répartit une adresse collée dans les champs, sans écraser ce que l'adresse ne précise pas.
    public mutating func apply(_ address: RemoteAddress) {
        if let proto = address.protocol, proto != `protocol` {
            `protocol` = proto
            port = proto.defaultPort
        }
        host = address.host
        if let port = address.port { self.port = port }
        if let username = address.username { self.username = username }
        if let path = address.path { self.path = path }
    }
}
