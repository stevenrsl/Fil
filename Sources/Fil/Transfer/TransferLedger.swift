import Foundation

/// Ce qu'un transfert a déjà écrit, pour que « Réessayer » reprenne au lieu de recommencer.
///
/// Règle de sécurité : on ne reprend **que** ce que Fil sait avoir écrit lui-même pendant cette session.
/// Rien n'est relu sur le disque ni sur le serveur pour deviner qu'un `.filpart` « doit être le bon » :
/// un vieux fichier partiel du même nom, complété puis publié, serait une corruption silencieuse.
final class TransferLedger: @unchecked Sendable {
    /// Téléchargement : le fichier partiel local et le nom final réservés, avec la taille distante vue au départ.
    struct LocalPartial: Sendable {
        let partial: URL
        let final: URL
        let remoteSize: Int64?
        /// Date du fichier distant vue au départ : deux écritures de même taille ne se distinguent que par elle.
        var remoteModified: Date? = nil
    }

    /// Envoi : le fichier partiel distant, avec la source telle qu'elle était au départ.
    struct RemotePartial: Sendable {
        let path: RemotePath
        let sourceSize: Int64
        let sourceModified: Date?
    }

    private let lock = NSLock()
    private var root: URL?
    private var done: [String: Int64] = [:]
    private var local: [String: LocalPartial] = [:]
    private var remote: [String: RemotePartial] = [:]

    // MARK: Dossier local d'un téléchargement de dossier

    var rootFolder: URL? {
        get { lock.withLock { root } }
        set { lock.withLock { root = newValue } }
    }

    // MARK: Fichiers terminés (clé : chemin distant)

    func isDone(_ key: String) -> Bool { lock.withLock { done[key] != nil } }
    func markDone(_ key: String, size: Int64) { lock.withLock { done[key] = size; local[key] = nil; remote[key] = nil } }
    var completedBytes: Int64 { lock.withLock { done.values.reduce(0, +) } }
    var completedCount: Int { lock.withLock { done.count } }

    // MARK: Partiels

    func localPartial(_ key: String) -> LocalPartial? { lock.withLock { local[key] } }
    func setLocalPartial(_ key: String, _ value: LocalPartial) { lock.withLock { local[key] = value } }
    func remotePartial(_ key: String) -> RemotePartial? { lock.withLock { remote[key] } }
    func setRemotePartial(_ key: String, _ value: RemotePartial) { lock.withLock { remote[key] = value } }
    func clearRemotePartial(_ key: String) { lock.withLock { remote[key] = nil } }

    /// Y a-t-il quelque chose à reprendre ?
    var hasProgress: Bool { lock.withLock { !done.isEmpty || !local.isEmpty || !remote.isEmpty } }

    struct Leftovers: Sendable {
        let localFiles: [URL]
        let remotePaths: [RemotePath]
        var isEmpty: Bool { localFiles.isEmpty && remotePaths.isEmpty }
    }

    /// Oublie tout et rend la liste des partiels à effacer.
    func takeLeftovers() -> Leftovers {
        lock.withLock {
            let leftovers = Leftovers(localFiles: local.values.map(\.partial), remotePaths: remote.values.map(\.path))
            root = nil
            done = [:]
            local = [:]
            remote = [:]
            return leftovers
        }
    }

    /// Efface seulement les partiels locaux, sans rien oublier : fin de session.
    func removeLocalPartials() {
        let files = lock.withLock { local.values.map(\.partial) }
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    func reset() {
        _ = takeLeftovers()
    }
}
