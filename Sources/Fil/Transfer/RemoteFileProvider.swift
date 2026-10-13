import Foundation

/// Octets déjà transférés pour le fichier en cours. Appelé depuis n'importe quel fil.
public typealias ProgressHandler = @Sendable (Int64) -> Void

/// Contrat commun à tous les protocoles. Aucun type de bibliothèque ne traverse cette frontière.
/// L'annulation passe par l'annulation de la tâche Swift appelante.
public protocol RemoteFileProvider: Sendable {
    var connection: RemoteConnection { get }
    /// Ouvre la session et renvoie le dossier où commencer.
    func connect() async throws -> RemotePath
    func list(_ directory: RemotePath) async throws -> [RemoteFile]
    /// Écrit le contenu à `destination`, créé ou remplacé.
    func download(_ file: RemoteFile, to destination: URL, progress: @escaping ProgressHandler) async throws
    /// Crée ou remplace le fichier distant `destination`.
    func upload(_ source: URL, to destination: RemotePath, progress: @escaping ProgressHandler) async throws
    func makeDirectory(_ path: RemotePath) async throws
    /// Supprime un fichier, ou un dossier avec tout son contenu.
    func delete(_ file: RemoteFile) async throws
}

public enum ProviderError: LocalizedError, Equatable, Sendable {
    case unavailable(RemoteProtocol)
    case hostNotFound(String)
    case connectionRefused(host: String, port: Int)
    case timedOut
    case authenticationFailed
    case hostKeyChanged(String)
    case certificateUntrusted
    case tlsUnavailable
    case notFound(String)
    case accessDenied(String)
    case alreadyExists(String)
    case connectionLost
    /// Message déjà formulé pour l'utilisateur.
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let proto):
            proto.unavailableReason ?? "Le protocole \(proto.label) n'est pas encore disponible."
        case .hostNotFound(let host):
            "Le serveur « \(host) » est introuvable. Vérifie l'adresse et la connexion à Internet."
        case .connectionRefused(let host, let port):
            "« \(host) » refuse la connexion sur le port \(port). Vérifie le port et le protocole."
        case .timedOut:
            "Le serveur ne répond pas. Il est peut-être éteint, ou un pare-feu bloque l'accès."
        case .authenticationFailed:
            "Identifiant ou mot de passe refusé par le serveur."
        case .hostKeyChanged(let host):
            "L'empreinte de « \(host) » a changé depuis la dernière connexion. Vérifie auprès de l'administrateur avant de continuer ; Fil refuse de se connecter en attendant."
        case .certificateUntrusted:
            "Le certificat du serveur n'est pas reconnu par macOS. Fil refuse de s'y connecter pour protéger ton mot de passe."
        case .tlsUnavailable:
            "Le serveur ne propose pas de connexion chiffrée. Choisis FTP seulement si le réseau est de confiance."
        case .notFound(let name):
            "« \(name) » n'existe pas ou plus sur le serveur."
        case .accessDenied(let name):
            "Le serveur refuse l'accès à « \(name) »."
        case .alreadyExists(let name):
            "« \(name) » existe déjà ici."
        case .connectionLost:
            "La connexion au serveur s'est interrompue."
        case .server(let message):
            message
        }
    }
}

/// Phrase lisible pour n'importe quelle erreur remontée jusqu'à l'interface.
enum ReadableError {
    static func message(for error: Error) -> String {
        if error is CancellationError { return "Annulé" }
        if let provider = error as? ProviderError { return provider.errorDescription ?? "Erreur inconnue." }
        if let url = error as? URLError { return message(for: url) }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteOutOfSpaceError: return "Il n'y a plus assez d'espace sur ce Mac."
            case NSFileWriteNoPermissionError: return "Fil n'a pas le droit d'écrire à cet endroit."
            case NSFileReadNoPermissionError: return "Fil n'a pas le droit de lire ce fichier."
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "Le fichier local a disparu."
            default: break
            }
        }
        if let localized = (error as? LocalizedError)?.errorDescription { return localized }
        return ns.localizedDescription
    }

    static func message(for error: URLError) -> String {
        switch error.code {
        case .cancelled: "Annulé"
        case .cannotFindHost, .dnsLookupFailed: "Le serveur est introuvable. Vérifie l'adresse et la connexion à Internet."
        case .cannotConnectToHost: "Le serveur refuse la connexion. Vérifie le port et le protocole."
        case .timedOut: "Le serveur ne répond pas. Il est peut-être éteint, ou un pare-feu bloque l'accès."
        case .notConnectedToInternet: "Ce Mac n'est pas connecté à Internet."
        case .networkConnectionLost: "La connexion au serveur s'est interrompue."
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .secureConnectionFailed:
            "Le certificat du serveur n'est pas reconnu par macOS. Fil refuse de s'y connecter pour protéger ton mot de passe."
        case .userAuthenticationRequired, .userCancelledAuthentication: "Identifiant ou mot de passe refusé par le serveur."
        default: "Erreur réseau (\(error.code.rawValue))."
        }
    }
}

/// Placeholder explicite : aucun faux transfert ne doit être présenté comme réel.
public actor PlannedProvider: RemoteFileProvider {
    public nonisolated let connection: RemoteConnection
    public init(connection: RemoteConnection) { self.connection = connection }
    public func connect() async throws -> RemotePath { throw ProviderError.unavailable(connection.protocol) }
    public func list(_ directory: RemotePath) async throws -> [RemoteFile] { throw ProviderError.unavailable(connection.protocol) }
    public func download(_ file: RemoteFile, to destination: URL, progress: @escaping ProgressHandler) async throws { throw ProviderError.unavailable(connection.protocol) }
    public func upload(_ source: URL, to destination: RemotePath, progress: @escaping ProgressHandler) async throws { throw ProviderError.unavailable(connection.protocol) }
    public func makeDirectory(_ path: RemotePath) async throws { throw ProviderError.unavailable(connection.protocol) }
    public func delete(_ file: RemoteFile) async throws { throw ProviderError.unavailable(connection.protocol) }
}

extension RemoteFileProvider {
    /// Crée le dossier s'il manque ; un dossier déjà présent n'est pas une erreur.
    func ensureDirectory(_ path: RemotePath) async throws {
        do {
            try await makeDirectory(path)
        } catch {
            if (try? await list(path)) != nil { return }
            throw error
        }
    }

    /// Tout le contenu d'un dossier, sous-dossiers compris, parents avant enfants.
    /// Les liens vers des dossiers ne sont pas suivis : un lien vers un parent bouclerait sans fin.
    func walk(_ directory: RemotePath, onProgress: @Sendable (Int) -> Void = { _ in }) async throws -> [RemoteFile] {
        var result: [RemoteFile] = []
        var fileCount = 0
        var pending = [directory]
        while let current = pending.popLast() {
            try Task.checkCancellation()
            for child in try await list(current) {
                if child.isSymbolicLink, child.kind != .file { continue }
                result.append(child)
                if child.isDirectory { pending.append(child.path) } else { fileCount += 1 }
            }
            onProgress(fileCount)
        }
        return result
    }
}

/// Suppression récursive pour les protocoles qui n'effacent que des dossiers vides.
func deleteTree(
    _ file: RemoteFile,
    list: (RemotePath) async throws -> [RemoteFile],
    removeFile: (RemotePath) async throws -> Void,
    removeDirectory: (RemotePath) async throws -> Void
) async throws {
    guard file.isDirectory, !file.isSymbolicLink else {
        try await removeFile(file.path)
        return
    }
    for child in try await list(file.path) {
        try Task.checkCancellation()
        try await deleteTree(child, list: list, removeFile: removeFile, removeDirectory: removeDirectory)
    }
    try await removeDirectory(file.path)
}
