import Foundation
import Observation

/// État de l'application : connexions, phase affichée, navigation ouverte, transferts.
@MainActor @Observable
final class AppModel {
    private(set) var phase: Phase = .choosing
    var connections: [RemoteConnection] {
        didSet {
            saveFavorites()
            // Une raison d'échec ne vaut que pour les réglages qui l'ont produite.
            if case .failed = phase { phase = .choosing }
        }
    }
    var selectedConnectionID: UUID? {
        didSet { if oldValue != selectedConnectionID { passwordDraft = "" } }
    }
    /// Saisie en cours, jamais persistée telle quelle : elle part au Keychain à la connexion.
    var passwordDraft = ""
    private(set) var browser: BrowserModel?
    private(set) var savedPasswordIDs: Set<UUID> = []
    /// FTP seulement : le serveur de la connexion ouverte accepte FTPS et l'utilisateur n'a pas dit non.
    private(set) var ftpsOfferedFor: UUID?
    var downloadFolder: URL {
        didSet { preferences.downloadFolder = downloadFolder }
    }
    var editorURL: URL? {
        didSet { preferences.editorURL = editorURL }
    }
    let transfers: TransferQueue
    #if os(macOS)
    let edits: EditCoordinator
    #endif

    @ObservationIgnored private var lastUsedID: UUID?
    @ObservationIgnored private let store: ConnectionStore
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let makeProvider: (RemoteConnection, String) -> any RemoteFileProvider
    @ObservationIgnored private let knownHosts: FilKnownHosts
    @ObservationIgnored private let certificates: PinnedCertificates
    #if os(macOS)
    @ObservationIgnored private let probeFTPS: (RemoteConnection, String) async -> FTPSProbe.Result
    @ObservationIgnored private let volumes: any FinderVolumes
    #endif
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Void, Never>?

    #if os(macOS)
    init(
        store: ConnectionStore = ConnectionStore(),
        preferences: Preferences = Preferences(),
        secrets: any SecretStore = KeychainStore(),
        transfers: TransferQueue = TransferQueue(),
        edits: EditCoordinator = EditCoordinator(),
        makeProvider: @escaping (RemoteConnection, String) -> any RemoteFileProvider = ProviderFactory.make,
        knownHosts: FilKnownHosts = .standard,
        certificates: PinnedCertificates = .standard,
        probeFTPS: @escaping (RemoteConnection, String) async -> FTPSProbe.Result = { await FTPSProbe.check($0, password: $1) },
        volumes: any FinderVolumes = NetFSVolumes()
    ) {
        self.volumes = volumes
        self.store = store
        self.preferences = preferences
        self.secrets = secrets
        self.transfers = transfers
        self.edits = edits
        self.makeProvider = makeProvider
        self.knownHosts = knownHosts
        self.certificates = certificates
        self.probeFTPS = probeFTPS
        let snapshot = store.load()
        self.connections = snapshot.connections
        self.lastUsedID = snapshot.lastUsedID
        self.downloadFolder = preferences.downloadFolder
        self.editorURL = preferences.editorURL
        self.selectedConnectionID = snapshot.connections.first { $0.id == snapshot.lastUsedID }?.id ?? snapshot.connections.first?.id
        self.savedPasswordIDs = Set(snapshot.connections.map(\.id).filter(secrets.hasPassword))
        edits.purgeStaleFolders()
        DragCache.purgeStale()
        // Un enregistrement vient d'arriver sur le serveur : si c'est le dossier affiché, il se met à jour.
        edits.onRemoteChanged = { [weak self] connectionID, directory in
            guard let browser = self?.browser, browser.connection.id == connectionID, browser.path == directory else { return }
            browser.refresh()
        }
    }
    #else
    /// iOS : ni modification sur place, ni Finder, ni FTP à sonder. Le reste est identique.
    init(
        store: ConnectionStore = ConnectionStore(),
        preferences: Preferences = Preferences(),
        secrets: any SecretStore = KeychainStore(),
        transfers: TransferQueue = TransferQueue(),
        makeProvider: @escaping (RemoteConnection, String) -> any RemoteFileProvider = ProviderFactory.make,
        knownHosts: FilKnownHosts = .standard,
        certificates: PinnedCertificates = .standard
    ) {
        self.store = store
        self.preferences = preferences
        self.secrets = secrets
        self.transfers = transfers
        self.makeProvider = makeProvider
        self.knownHosts = knownHosts
        self.certificates = certificates
        let snapshot = store.load()
        self.connections = snapshot.connections
        self.lastUsedID = snapshot.lastUsedID
        self.downloadFolder = preferences.downloadFolder
        self.editorURL = preferences.editorURL
        self.selectedConnectionID = snapshot.connections.first { $0.id == snapshot.lastUsedID }?.id ?? snapshot.connections.first?.id
        self.savedPasswordIDs = Set(snapshot.connections.map(\.id).filter(secrets.hasPassword))
    }
    #endif

    // MARK: Lecture

    var selectedConnection: RemoteConnection? {
        connections.first { $0.id == selectedConnectionID }
    }

    var readiness: Readiness { .connecting(selectedConnection) }

    /// Connexions épinglées, dans l'ordre de la liste : la n-ième s'ouvre avec ⌘n.
    var favoriteConnections: [RemoteConnection] { connections.filter(\.isFavorite) }
    var otherConnections: [RemoteConnection] { connections.filter { !$0.isFavorite } }

    /// Faut-il montrer la proposition de passer en FTPS sur la page ouverte ?
    var hasFTPSOffer: Bool {
        guard let ftpsOfferedFor else { return false }
        return ftpsOfferedFor == activeConnectionID && phase.isBrowsing
    }

    var hasSavedPassword: Bool {
        selectedConnectionID.map(savedPasswordIDs.contains) ?? false
    }

    /// Connexion actuellement ouverte ou en cours d'ouverture.
    var activeConnectionID: UUID? {
        switch phase {
        case .connecting(let connection), .browsing(let connection): connection.id
        default: nil
        }
    }

    // MARK: Connexions

    /// Choisir une autre connexion quitte celle qui est ouverte ; rechoisir la même ne change rien.
    func select(_ id: UUID) {
        if let active = activeConnectionID, active != id { leave() }
        selectedConnectionID = id
        if let shown = phase.connection, shown.id != id, !phase.isBrowsing, !phase.isConnecting { phase = .choosing }
    }

    func addConnection() {
        leave()
        let connection = RemoteConnection(name: "Nouvelle connexion")
        connections.append(connection)
        selectedConnectionID = connection.id
        phase = .choosing
    }

    func deleteConnection(_ id: UUID) {
        if phase.connection?.id == id { leave() }
        secrets.deletePassword(for: id)
        savedPasswordIDs.remove(id)
        let index = connections.firstIndex { $0.id == id }
        connections.removeAll { $0.id == id }
        if selectedConnectionID == id {
            let next = index.map { min($0, connections.count - 1) } ?? -1
            selectedConnectionID = next >= 0 ? connections[next].id : nil
        }
        phase = .choosing
    }

    func updateConnection(_ id: UUID, _ change: (inout RemoteConnection) -> Void) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        let before = connections[index]
        var connection = before
        change(&connection)
        // Un certificat approuvé ne vaut que pour le serveur qu'on a vu : une autre adresse, un autre port
        // ou un autre protocole, et la confiance ne suit pas.
        if connection.trustedCertificate == before.trustedCertificate,
           connection.host != before.host || connection.port != before.port || connection.protocol != before.protocol {
            connection.trustedCertificate = nil
        }
        if connection != before { connections[index] = connection }
    }

    func updateProtocol(_ id: UUID, to value: RemoteProtocol) {
        updateConnection(id) { connection in
            guard connection.protocol != value else { return }
            if connection.port == connection.protocol.defaultPort { connection.port = value.defaultPort }
            connection.protocol = value
        }
    }

    /// Une URL collée (`sftp://moi@hôte:2222/www`) se répartit tout de suite dans les champs.
    func updateHost(_ id: UUID, to text: String) {
        updateConnection(id) { connection in
            if text.contains("://"), let address = RemoteAddress(parsing: text) {
                connection.apply(address)
            } else {
                connection.host = text
            }
        }
    }

    /// À la validation du champ, `moi@hôte:2222` se répartit aussi.
    func commitHost(_ id: UUID) {
        updateConnection(id) { connection in
            if let address = RemoteAddress(parsing: connection.host) { connection.apply(address) }
            connection.host = connection.host.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func toggleFavorite(_ id: UUID) {
        updateConnection(id) { $0.isFavorite.toggle() }
    }

    /// ⌘1 à ⌘9 : ouvre le favori, ou l'affiche s'il lui manque un réglage. Déjà ouvert, rien ne bouge.
    func openFavorite(at index: Int) {
        let favorites = favoriteConnections
        guard favorites.indices.contains(index) else { return }
        let id = favorites[index].id
        guard activeConnectionID != id else { return }
        select(id)
        if readiness.isReady { connect() }
    }

    func forgetPassword(_ id: UUID) {
        secrets.deletePassword(for: id)
        savedPasswordIDs.remove(id)
    }

    // MARK: Session

    func connect() {
        guard let connection = selectedConnection, readiness.isReady, !phase.isConnecting else { return }
        if activeConnectionID != nil { leave() }

        let typed = passwordDraft
        if !typed.isEmpty {
            do {
                try secrets.save(password: typed, for: connection.id, label: connection.name)
                savedPasswordIDs.insert(connection.id)
            } catch {
                phase = .failed(connection, reason: ReadableError.message(for: error))
                return
            }
        }
        passwordDraft = ""
        // SFTP relit lui-même le Keychain au moment où ssh le demande.
        let password = connection.protocol == .sftp ? "" : (typed.isEmpty ? secrets.password(for: connection.id) ?? "" : typed)

        lastUsedID = connection.id
        saveFavorites()
        phase = .connecting(connection)
        let provider = makeProvider(connection, password)
        connectTask = Task { [weak self] in
            do {
                let home = try await provider.connect()
                guard let self, case .connecting(let current) = self.phase, current.id == connection.id else { return }
                #if os(macOS)
                let finder = FinderMount.isSupported(connection.protocol) ? FinderAccess(volumes: self.volumes, password: password) : nil
                self.browser = BrowserModel(connection: connection, provider: provider, home: home, transfers: self.transfers, edits: self.edits, finder: finder) { [weak self] in
                    self?.downloadFolder ?? Preferences().downloadFolder
                }
                #else
                self.browser = BrowserModel(connection: connection, provider: provider, home: home, transfers: self.transfers) { [weak self] in
                    self?.downloadFolder ?? Preferences().downloadFolder
                }
                #endif
                self.phase = .browsing(connection)
                self.startFTPSProbe(for: connection, password: password)
            } catch {
                guard let self, case .connecting(let current) = self.phase, current.id == connection.id else { return }
                self.phase = self.phase(after: error, for: connection)
            }
        }
    }

    func cancelConnecting() {
        guard phase.isConnecting else { return }
        connectTask?.cancel()
        connectTask = nil
        phase = .choosing
    }

    /// Où mène un échec de connexion : une confirmation à demander, un abandon, ou une raison à lire.
    private func phase(after error: Error, for connection: RemoteConnection) -> Phase {
        if error is CancellationError { return .choosing }
        if case .certificateChanged(_, let presented?) = error as? ProviderError, let previous = connection.trustedCertificate {
            return .confirming(connection, .certificateReplacement(previous: previous, presented: presented))
        }
        switch error as? ProviderError {
        case .hostKeyUnknown(let keys) where !keys.isEmpty: return .confirming(connection, .hostKey(keys))
        case .certificateToConfirm(let certificate): return .confirming(connection, .certificate(certificate))
        // Un serveur approuvé change de clé ou de certificat : refus par défaut, mais avec un geste explicite
        // (ancien et nouveau côte à côte) quand on a pu relever ce qu'il présente maintenant.
        case .hostKeyChanged(_, let presented) where !presented.isEmpty:
            return .confirming(connection, .hostKeyReplacement(previous: knownHosts.previousKeys(for: presented), presented: presented))
        default: return .failed(connection, reason: ReadableError.message(for: error))
        }
    }

    // MARK: Confiance

    /// L'utilisateur a vérifié l'empreinte : on la retient, puis on se connecte pour de bon.
    func confirmTrust() {
        guard case .confirming(let connection, let request) = phase else { return }
        do {
            switch request {
            case .hostKey(let keys):
                try knownHosts.trust(keys)
            case .certificate(let certificate):
                try certificates.save(certificate)
                updateConnection(connection.id) {
                    $0.trustedCertificate = TrustedCertificate(sha256: certificate.sha256, subject: certificate.subject)
                }
            case .hostKeyReplacement(_, let presented):
                try knownHosts.replace(with: presented)
            case .certificateReplacement(let previous, let presented):
                try certificates.save(presented)
                updateConnection(connection.id) {
                    $0.trustedCertificate = TrustedCertificate(sha256: presented.sha256, subject: presented.subject)
                }
                // L'ancien fichier ne sert plus qu'aux connexions qui l'approuvent encore.
                if !connections.contains(where: { $0.trustedCertificate?.sha256 == previous.sha256 }) {
                    certificates.remove(previous.sha256)
                }
            }
        } catch {
            phase = .failed(connection, reason: ReadableError.message(for: error))
            return
        }
        selectedConnectionID = connection.id
        phase = .choosing
        connect()
    }

    func declineTrust() {
        guard phase.isConfirming else { return }
        phase = .choosing
    }

    /// Retire l'approbation d'un certificat : la prochaine connexion redemandera de le vérifier.
    func forgetCertificate(_ id: UUID) {
        guard let pinned = connections.first(where: { $0.id == id })?.trustedCertificate else { return }
        updateConnection(id) { $0.trustedCertificate = nil }
        // Le fichier ne sert plus qu'aux connexions qui approuvent encore ce certificat.
        if !connections.contains(where: { $0.trustedCertificate?.sha256 == pinned.sha256 }) {
            certificates.remove(pinned.sha256)
        }
    }

    // MARK: Proposition FTPS

    /// Teste en arrière-plan, sur une connexion à part, si ce serveur FTP accepte aussi FTPS.
    private func startFTPSProbe(for connection: RemoteConnection, password: String) {
        probeTask?.cancel()
        ftpsOfferedFor = nil
        #if os(macOS)
        let current = connections.first { $0.id == connection.id } ?? connection
        guard current.protocol == .ftp, !current.ftpsOfferDismissed else { return }
        let probe = probeFTPS
        probeTask = Task { [weak self] in
            let result = await probe(current, password)
            guard let self, !Task.isCancelled, result == .available,
                  case .browsing(let open) = self.phase, open.id == connection.id else { return }
            self.ftpsOfferedFor = connection.id
        }
        #endif
    }

    /// Passe la connexion en FTPS et la rouvre : les mots de passe et fichiers suivants sont chiffrés.
    func acceptFTPSOffer() {
        guard let id = ftpsOfferedFor else { return }
        ftpsOfferedFor = nil
        updateProtocol(id, to: .ftps)
        closeConnection()
        selectedConnectionID = id
        connect()
    }

    /// « Ne plus proposer » : pour ce serveur, définitivement.
    func dismissFTPSOffer() {
        guard let id = ftpsOfferedFor else { return }
        ftpsOfferedFor = nil
        updateConnection(id) { $0.ftpsOfferDismissed = true }
    }

    /// Ferme la navigation. Les transferts lancés continuent : ils gardent leur fournisseur.
    func closeConnection() {
        leave()
    }

    private func leave() {
        connectTask?.cancel()
        connectTask = nil
        probeTask?.cancel()
        probeTask = nil
        ftpsOfferedFor = nil
        browser = nil
        if phase.isConnecting || phase.isBrowsing { phase = .choosing }
    }

    private func saveFavorites() {
        store.save(.init(connections: connections, lastUsedID: lastUsedID))
    }
}
