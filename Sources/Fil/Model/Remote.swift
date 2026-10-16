import Foundation

public enum RemoteProtocol: String, CaseIterable, Codable, Sendable, Identifiable {
    case ftp, ftps, sftp, webdav, kdrive, protonDrive

    public var id: Self { self }

    public var label: String {
        switch self {
        case .ftp: "FTP"
        case .ftps: "FTPS"
        case .sftp: "SFTP"
        case .webdav: "WebDAV"
        case .kdrive: "kDrive"
        case .protonDrive: "Proton Drive"
        }
    }

    /// Raison lisible quand le protocole n'est pas encore branché, `nil` sinon.
    public var unavailableReason: String? {
        switch self {
        case .protonDrive: "Proton Drive passera par le CLI officiel de Proton. Cette intégration n'est pas encore branchée."
        default: nil
        }
    }

    public var isAvailable: Bool { unavailableReason == nil }

    /// Les WebDAV passent l'adresse à la racine WebDAV ; les autres partent du dossier personnel.
    public var pathIsRoot: Bool { self == .webdav || self == .kdrive }

    public var defaultPort: Int {
        switch self {
        case .ftp, .ftps: 21
        case .sftp: 22
        case .webdav, .kdrive: 443
        case .protonDrive: 0
        }
    }
}

public struct RemoteConnection: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var `protocol`: RemoteProtocol
    public var username: String
    /// FTP, FTPS, SFTP : dossier d'arrivée, absolu ou relatif au dossier personnel (vide = dossier personnel).
    /// WebDAV, kDrive : racine WebDAV sur le serveur, au-dessus de laquelle on ne remonte pas (vide = `/`).
    public var path: String
    /// FTP seulement : l'utilisateur a refusé qu'on lui propose FTPS pour ce serveur.
    public var ftpsOfferDismissed: Bool
    /// FTPS, WebDAV, kDrive : le certificat que l'utilisateur a approuvé pour ce serveur, faute de
    /// chaîne que macOS reconnaisse (NAS, serveur personnel). Fil ne se connecte alors qu'à lui.
    public var trustedCertificate: TrustedCertificate?

    public init(id: UUID = UUID(), name: String = "Nouvelle connexion", host: String = "", port: Int? = nil, protocol: RemoteProtocol = .sftp, username: String = "", path: String = "", ftpsOfferDismissed: Bool = false, trustedCertificate: TrustedCertificate? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port ?? `protocol`.defaultPort
        self.protocol = `protocol`
        self.username = username
        self.path = path
        self.ftpsOfferDismissed = ftpsOfferDismissed
        self.trustedCertificate = trustedCertificate
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, `protocol`, username, path, ftpsOfferDismissed, trustedCertificate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Connexion"
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        `protocol` = try container.decodeIfPresent(RemoteProtocol.self, forKey: .protocol) ?? .sftp
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? `protocol`.defaultPort
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        ftpsOfferDismissed = try container.decodeIfPresent(Bool.self, forKey: .ftpsOfferDismissed) ?? false
        trustedCertificate = try container.decodeIfPresent(TrustedCertificate.self, forKey: .trustedCertificate)
    }

    public static func defaultPort(for proto: RemoteProtocol) -> Int { proto.defaultPort }

    /// Adresse réellement contactée. Pour kDrive, un identifiant numérique seul suffit.
    public var resolvedHost: String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if `protocol` == .kdrive, !trimmed.isEmpty, trimmed.allSatisfy(\.isASCIIDigit) {
            return "\(trimmed).connect.kdrive.infomaniak.com"
        }
        return trimmed
    }

    /// Résumé d'une ligne : « SFTP · steven@exemple.fr:2222 ».
    public var summary: String {
        let host = resolvedHost
        guard !host.isEmpty else { return `protocol`.label }
        let user = username.isEmpty ? "" : "\(username)@"
        let port = port == `protocol`.defaultPort ? "" : ":\(port)"
        return "\(`protocol`.label) · \(user)\(host)\(port)"
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// Chemin distant absolu et normalisé : commence par `/`, sans `/` final, sans `.` ni `..`.
public struct RemotePath: Hashable, Sendable, CustomStringConvertible {
    public let value: String

    public init(_ raw: String) {
        var parts: [Substring] = []
        for part in raw.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        value = "/" + parts.joined(separator: "/")
    }

    public static let root = RemotePath("/")

    public var isRoot: Bool { value == "/" }
    public var components: [String] { value.split(separator: "/").map(String.init) }
    public var name: String { components.last ?? "/" }
    public var parent: RemotePath? { isRoot ? nil : RemotePath(components.dropLast().joined(separator: "/")) }
    public var description: String { value }

    public func appending(_ relative: String) -> RemotePath { RemotePath(value + "/" + relative) }

    /// Nom sous lequel un fichier est envoyé avant d'être renommé : `rapport.pdf` → `rapport.pdf.filpart`.
    public var partialSibling: RemotePath {
        (parent ?? .root).appending(name + ".filpart")
    }

    /// Chemins successifs de la racine jusqu'à ce chemin compris.
    public var lineage: [RemotePath] {
        var result = [RemotePath.root]
        var current = RemotePath.root
        for component in components {
            current = current.appending(component)
            result.append(current)
        }
        return result
    }

    public func hasPrefix(_ other: RemotePath) -> Bool {
        other.isRoot || value == other.value || value.hasPrefix(other.value + "/")
    }

    /// Résout un chemin saisi par l'utilisateur : absolu tel quel, relatif depuis `base`.
    public static func resolve(_ input: String, from base: RemotePath) -> RemotePath {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return base }
        if trimmed.hasPrefix("/") { return RemotePath(trimmed) }
        if trimmed == "~" { return base }
        if trimmed.hasPrefix("~/") { return base.appending(String(trimmed.dropFirst(2))) }
        return base.appending(trimmed)
    }
}

public struct RemoteFile: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case file, directory
        /// Lien symbolique dont la cible n'a pas pu être déterminée (FTP `LIST`).
        case link
    }

    public var id: String { path.value }
    public let name: String
    public let path: RemotePath
    public let kind: Kind
    public let byteCount: Int64?
    public let modifiedAt: Date?
    /// Un lien n'est jamais suivi pour supprimer ni pour parcourir : on agit sur le lien lui-même.
    public let isSymbolicLink: Bool

    public init(name: String, path: RemotePath, kind: Kind, byteCount: Int64? = nil, modifiedAt: Date? = nil, isSymbolicLink: Bool = false) {
        self.name = name
        self.path = path
        self.kind = kind
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.isSymbolicLink = isSymbolicLink || kind == .link
    }

    public var isDirectory: Bool { kind == .directory }
}
