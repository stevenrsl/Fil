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
    var downloadFolder: URL {
        didSet { preferences.downloadFolder = downloadFolder }
    }
    let transfers: TransferQueue

    @ObservationIgnored private var lastUsedID: UUID?
    @ObservationIgnored private let store: ConnectionStore
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let makeProvider: (RemoteConnection, String) -> any RemoteFileProvider
    @ObservationIgnored private var connectTask: Task<Void, Never>?

    init(
        store: ConnectionStore = ConnectionStore(),
        preferences: Preferences = Preferences(),
        secrets: any SecretStore = KeychainStore(),
        transfers: TransferQueue = TransferQueue(),
        makeProvider: @escaping (RemoteConnection, String) -> any RemoteFileProvider = ProviderFactory.make
    ) {
        self.store = store
        self.preferences = preferences
        self.secrets = secrets
        self.transfers = transfers
        self.makeProvider = makeProvider
        let snapshot = store.load()
        self.connections = snapshot.connections
        self.lastUsedID = snapshot.lastUsedID
        self.downloadFolder = preferences.downloadFolder
        self.selectedConnectionID = snapshot.connections.first { $0.id == snapshot.lastUsedID }?.id ?? snapshot.connections.first?.id
        self.savedPasswordIDs = Set(snapshot.connections.map(\.id).filter(secrets.hasPassword))
    }

    // MARK: Lecture

    var selectedConnection: RemoteConnection? {
        connections.first { $0.id == selectedConnectionID }
    }

    var readiness: Readiness { .connecting(selectedConnection) }

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
        if case .failed(let connection, _) = phase, connection.id != id { phase = .choosing }
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
        var connection = connections[index]
        change(&connection)
        if connection != connections[index] { connections[index] = connection }
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
                self.browser = BrowserModel(connection: connection, provider: provider, home: home, transfers: self.transfers) { [weak self] in
                    self?.downloadFolder ?? Preferences().downloadFolder
                }
                self.phase = .browsing(connection)
            } catch {
                guard let self, case .connecting(let current) = self.phase, current.id == connection.id else { return }
                self.phase = error is CancellationError ? .choosing : .failed(connection, reason: ReadableError.message(for: error))
            }
        }
    }

    func cancelConnecting() {
        guard phase.isConnecting else { return }
        connectTask?.cancel()
        connectTask = nil
        phase = .choosing
    }

    /// Ferme la navigation. Les transferts lancés continuent : ils gardent leur fournisseur.
    func closeConnection() {
        leave()
    }

    private func leave() {
        connectTask?.cancel()
        connectTask = nil
        browser = nil
        if phase.isConnecting || phase.isBrowsing { phase = .choosing }
    }

    private func saveFavorites() {
        store.save(.init(connections: connections, lastUsedID: lastUsedID))
    }
}
