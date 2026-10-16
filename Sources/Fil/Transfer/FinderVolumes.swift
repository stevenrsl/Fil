import AppKit
import Foundation
import NetFS

/// Monte une racine distante comme volume et la montre dans le Finder. NetFS en production,
/// un double dans les tests.
protocol FinderVolumes: Sendable {
    /// Monte `url` (ou retrouve le volume déjà monté) et renvoie son point de montage.
    func mount(_ url: URL, user: String, password: String) async throws -> URL
    @MainActor func reveal(_ folder: URL)
}

/// Ce qu'il faut pour ouvrir une connexion dans le Finder : le monteur et le mot de passe de la session.
struct FinderAccess: Sendable {
    let volumes: any FinderVolumes
    let password: String
}

/// Quelles connexions le Finder sait monter, et à quelle adresse.
enum FinderMount {
    enum Target: Equatable {
        case url(URL)
        case blocked(String)
    }

    /// Le Finder ne monte en écriture que WebDAV : FTP y serait en lecture seule, FTPS et SFTP n'y sont pas.
    static func isSupported(_ proto: RemoteProtocol) -> Bool { proto == .webdav || proto == .kdrive }

    static func target(for connection: RemoteConnection) -> Target {
        guard isSupported(connection.protocol) else {
            return .blocked("Le Finder ne sait monter que WebDAV et kDrive. Les autres protocoles restent dans Fil.")
        }
        // Le Finder ne connaît pas les certificats approuvés dans Fil : il refuserait le serveur.
        if connection.trustedCertificate != nil {
            return .blocked("Ce serveur n'est approuvé que dans Fil. Le Finder ne reconnaît pas son certificat.")
        }
        let root = WebDAVProvider.defaultRoot(for: connection)
        return .url(root.hasDirectoryPath ? root : root.appendingPathComponent("", isDirectory: true))
    }

    /// Dossier local qui correspond à `path` dans le volume monté.
    static func folder(for path: RemotePath, in mountPoint: URL) -> URL {
        path.components.reduce(mountPoint) { $0.appendingPathComponent($1, isDirectory: true) }
    }
}

/// Montage par NetFS, comme « Se connecter au serveur » du Finder, sans fenêtre système.
struct NetFSVolumes: FinderVolumes {
    func mount(_ url: URL, user: String, password: String) async throws -> URL {
        if let existing = Self.mountedVolume(for: url) { return existing }
        let open = NSMutableDictionary()
        open[kNAUIOptionKey] = kNAUIOptionNoUI
        if user.isEmpty { open[kNetFSUseGuestKey] = true }
        let mountOptions = NSMutableDictionary()
        return try await withCheckedThrowingContinuation { continuation in
            var request: AsyncRequestID?
            let status = NetFSMountURLAsync(
                url as CFURL, nil,
                user.isEmpty ? nil : user as CFString,
                user.isEmpty ? nil : password as CFString,
                open as CFMutableDictionary, mountOptions as CFMutableDictionary,
                &request, DispatchQueue.global()
            ) { status, _, points in
                let first = (points as? [String])?.first
                if status == 0, let first {
                    continuation.resume(returning: URL(fileURLWithPath: first, isDirectory: true))
                } else if status == EEXIST, let existing = Self.mountedVolume(for: url) {
                    continuation.resume(returning: existing)
                } else {
                    continuation.resume(throwing: FinderMountError(status: status == 0 ? ENOENT : status, host: url.host ?? ""))
                }
            }
            if status != 0 {
                continuation.resume(throwing: FinderMountError(status: status, host: url.host ?? ""))
            }
        }
    }

    @MainActor func reveal(_ folder: URL) {
        NSWorkspace.shared.open(folder)
    }

    /// Volume déjà monté depuis la même adresse, par Fil ou par « Se connecter au serveur ».
    static func mountedVolume(for url: URL) -> URL? {
        let wanted = comparable(url)
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey], options: [.skipHiddenVolumes]) ?? []
        return volumes.first { volume in
            guard let remote = try? volume.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting else { return false }
            return comparable(remote) == wanted
        }
    }

    /// Adresse sans identifiant ni barre finale, hôte en minuscules.
    private static func comparable(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.user = nil
        parts.password = nil
        parts.host = parts.host?.lowercased()
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        parts.percentEncodedPath = path
        return parts.string ?? url.absoluteString
    }
}

/// Refus de NetFS, en clair. Les codes sont des `errno` ou des codes NetFS.
struct FinderMountError: LocalizedError, Equatable, Sendable {
    let status: Int32
    let host: String

    var errorDescription: String? {
        switch status {
        case EAUTH, EACCES, EPERM:
            "« \(host) » refuse l'identifiant ou le mot de passe dans le Finder."
        case ETIMEDOUT:
            "« \(host) » ne répond pas. Le Finder n'a pas pu le monter."
        case ECONNREFUSED, EHOSTUNREACH, ENETUNREACH, EHOSTDOWN:
            "Le Finder n'arrive pas à joindre « \(host) ». Vérifie l'adresse et la connexion à Internet."
        case ECANCELED, Int32(userCanceledErr):
            "Annulé"
        default:
            "Le Finder n'a pas pu monter « \(host) » (code \(status))."
        }
    }
}
