import XCTest
@testable import Fil

@MainActor
final class BrowserModelTests: XCTestCase {
    private func makeBrowser(_ provider: MockProvider, home: RemotePath = .root) -> BrowserModel {
        BrowserModel(connection: provider.connection, provider: provider, home: home, transfers: TransferQueue()) {
            FileManager.default.temporaryDirectory
        }
    }

    func testListsDirectoriesFirstThenNaturalOrder() async {
        let provider = MockProvider(files: ["/b10.txt": "x", "/b2.txt": "x", "/zdir/a": "x", "/A.txt": "x"])
        let browser = makeBrowser(provider)
        XCTAssertEqual(browser.waitingPhrase, "Lecture de « simule.test »…")
        await waitUntil("listing") { browser.status == .ready }
        XCTAssertEqual(browser.visibleFiles.map(\.name), ["zdir", "A.txt", "b2.txt", "b10.txt"])
        browser.sortKey = .size
        browser.ascending = false
        XCTAssertEqual(browser.visibleFiles.first?.name, "zdir")
        browser.filter = "b1"
        XCTAssertEqual(browser.visibleFiles.map(\.name), ["b10.txt"])
    }

    func testNavigationAndGoingUpSelectsPreviousFolder() async {
        let provider = MockProvider(files: ["/srv/www/index.html": "x"])
        let browser = makeBrowser(provider, home: RemotePath("/srv/www"))
        await waitUntil("listing") { browser.status == .ready }
        XCTAssertEqual(browser.title, "www")
        browser.goUp()
        await waitUntil("parent") { browser.path == RemotePath("/srv") && browser.status == .ready }
        XCTAssertEqual(browser.selection, ["/srv/www"])
        browser.open(["/srv/www"])
        await waitUntil("retour") { browser.path == RemotePath("/srv/www") }
    }

    func testFailureClearsTheListingAndExplains() async {
        let provider = MockProvider(files: ["/a.txt": "x"])
        let browser = makeBrowser(provider)
        await waitUntil("listing") { browser.status == .ready }
        await provider.set(listError: ProviderError.accessDenied("/"))
        browser.refresh()
        await waitUntil("échec") { browser.status != .ready }
        XCTAssertEqual(browser.status, .failed("Le serveur refuse l'accès à « / »."))
        XCTAssertTrue(browser.files.isEmpty)
    }

    func testCreateFolderValidatesTheName() async {
        let provider = MockProvider(files: ["/existe/a": "x"])
        let browser = makeBrowser(provider)
        await waitUntil("listing") { browser.status == .ready }
        XCTAssertEqual(browser.folderNameProblem("  "), "Donne un nom au dossier.")
        XCTAssertEqual(browser.folderNameProblem("a/b"), "Le nom ne peut pas contenir de « / ».")
        XCTAssertEqual(browser.folderNameProblem("existe"), "« existe » existe déjà ici.")
        browser.createFolder(named: "Nouveau")
        await waitUntil("dossier créé") { browser.files.contains { $0.name == "Nouveau" } }
        XCTAssertEqual(browser.selection, ["/Nouveau"])
    }

    func testDeleteRemovesRecursively() async {
        let provider = MockProvider(files: ["/vieux/a/b.txt": "x", "/garde.txt": "y"])
        let browser = makeBrowser(provider)
        await waitUntil("listing") { browser.status == .ready }
        browser.delete(browser.files.filter { $0.name == "vieux" })
        await waitUntil("supprimé") { browser.activity == nil && browser.files.map(\.name) == ["garde.txt"] }
        let tree = await provider.tree
        XCTAssertNil(tree[RemotePath("/vieux/a")])
    }

    func testUploadConflictsAreDetected() async {
        let provider = MockProvider(files: ["/a.txt": "x"])
        let browser = makeBrowser(provider)
        await waitUntil("listing") { browser.status == .ready }
        XCTAssertEqual(browser.conflicts(for: [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]), ["a.txt"])
    }

    func testFootnote() async {
        let provider = MockProvider(files: ["/a.txt": "12345", "/b.txt": "1"])
        let browser = makeBrowser(provider)
        await waitUntil("listing") { browser.status == .ready }
        let plain = { (text: String) in text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ") }
        XCTAssertEqual(plain(browser.footnote), "2 éléments · 6 octets")
        browser.selection = ["/a.txt"]
        XCTAssertEqual(plain(browser.footnote), "1 sélectionné sur 2 · 5 octets")
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var secrets: MemorySecretStore!

    override func setUp() async throws {
        // Nom fixe, vidé à chaque fois : aucun domaine de préférences ne s'accumule.
        suite = "FilTests.\(Self.self)"
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
        secrets = MemorySecretStore()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeModel(provider: @escaping (RemoteConnection, String) -> any RemoteFileProvider) -> AppModel {
        AppModel(store: ConnectionStore(defaults: defaults), preferences: Preferences(defaults: defaults), secrets: secrets, makeProvider: provider)
    }

    func testEditsArePersistedImmediately() {
        let model = makeModel { connection, _ in MockProvider(connection: connection) }
        model.addConnection()
        let id = model.selectedConnectionID!
        model.updateConnection(id) { $0.name = "Atelier" }
        model.updateConnection(id) { $0.port = 2222 }
        let reloaded = ConnectionStore(defaults: defaults).load().connections
        XCTAssertEqual(reloaded.first?.name, "Atelier")
        XCTAssertEqual(reloaded.first?.port, 2222)
    }

    func testPastedURLFillsTheFields() {
        let model = makeModel { connection, _ in MockProvider(connection: connection) }
        model.addConnection()
        let id = model.selectedConnectionID!
        model.updateHost(id, to: "sftp://moi@exemple.fr:2222/var/www")
        XCTAssertEqual(model.selectedConnection?.protocol, .sftp)
        XCTAssertEqual(model.selectedConnection?.host, "exemple.fr")
        XCTAssertEqual(model.selectedConnection?.port, 2222)
        XCTAssertEqual(model.selectedConnection?.username, "moi")
        XCTAssertEqual(model.selectedConnection?.path, "/var/www")
    }

    func testProtocolChangeKeepsACustomPort() {
        let model = makeModel { connection, _ in MockProvider(connection: connection) }
        model.addConnection()
        let id = model.selectedConnectionID!
        model.updateProtocol(id, to: .ftp)
        XCTAssertEqual(model.selectedConnection?.port, 21)
        model.updateConnection(id) { $0.port = 2121 }
        model.updateProtocol(id, to: .ftps)
        XCTAssertEqual(model.selectedConnection?.port, 2121)
    }

    func testConnectSavesThePasswordInTheSecretStoreAndBrowses() async {
        var receivedPassword: String?
        let model = makeModel { connection, password in
            receivedPassword = password
            return MockProvider(connection: connection, home: RemotePath("/home/moi"), files: ["/home/moi/a.txt": "x"])
        }
        model.addConnection()
        let id = model.selectedConnectionID!
        model.updateConnection(id) { $0.host = "exemple.fr"; $0.protocol = .ftps }
        model.passwordDraft = "s3cret"
        model.connect()
        XCTAssertEqual(model.phase, .connecting(model.selectedConnection!))
        await waitUntil("navigation") { model.phase.isBrowsing }

        XCTAssertEqual(receivedPassword, "s3cret")
        XCTAssertEqual(secrets.password(for: id), "s3cret")
        XCTAssertTrue(model.hasSavedPassword)
        XCTAssertEqual(model.passwordDraft, "")
        XCTAssertEqual(model.browser?.path, RemotePath("/home/moi"))
        let raw = String(decoding: defaults.data(forKey: ConnectionStore.key)!, as: UTF8.self)
        XCTAssertFalse(raw.contains("s3cret"))
    }

    func testSavedPasswordIsReusedAndSFTPGetsNone() async {
        var received: [String] = []
        let model = makeModel { connection, password in
            received.append(password)
            return MockProvider(connection: connection)
        }
        model.addConnection()
        let id = model.selectedConnectionID!
        try? secrets.save(password: "garde", for: id, label: "x")
        model.updateConnection(id) { $0.host = "exemple.fr"; $0.protocol = .webdav }
        model.connect()
        await waitUntil("navigation WebDAV") { model.phase.isBrowsing }
        model.closeConnection()
        model.updateProtocol(id, to: .sftp)
        model.connect()
        await waitUntil("navigation SFTP") { model.phase.isBrowsing }
        XCTAssertEqual(received, ["garde", ""])
    }

    func testFailureShowsAReasonThatAnEditClears() async {
        let model = makeModel { connection, _ in
            let provider = MockProvider(connection: connection)
            Task { await provider.set(connectError: ProviderError.authenticationFailed) }
            return provider
        }
        model.addConnection()
        let id = model.selectedConnectionID!
        model.updateConnection(id) { $0.host = "exemple.fr" }
        try? await Task.sleep(for: .milliseconds(20))
        model.connect()
        await waitUntil("échec") { if case .failed = model.phase { true } else { false } }
        XCTAssertEqual(model.phase, .failed(model.selectedConnection!, reason: "Identifiant ou mot de passe refusé par le serveur."))
        model.updateConnection(id) { $0.username = "autre" }
        XCTAssertEqual(model.phase, .choosing)
    }

    func testKeychainRefusalIsABlockingReason() {
        secrets.failure = KeychainError(status: errSecUserCanceled)
        let model = makeModel { connection, _ in MockProvider(connection: connection) }
        model.addConnection()
        model.updateConnection(model.selectedConnectionID!) { $0.host = "exemple.fr" }
        model.passwordDraft = "x"
        model.connect()
        XCTAssertEqual(model.phase, .failed(model.selectedConnection!, reason: "L'accès au trousseau a été refusé. Le mot de passe n'a pas été enregistré."))
    }

    func testTransfersSurviveClosingTheConnection() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let provider = MockProvider(files: ["/lent.bin": String(repeating: "x", count: 100)])
        await provider.set(chunkDelay: .milliseconds(2))
        let model = makeModel { _, _ in provider }
        model.downloadFolder = folder
        model.addConnection()
        model.updateConnection(model.selectedConnectionID!) { $0.host = "exemple.fr" }
        model.connect()
        await waitUntil("navigation") { model.browser?.status == .ready }
        model.browser?.download(model.browser!.files)
        model.closeConnection()
        XCTAssertNil(model.browser)
        XCTAssertEqual(model.phase, .choosing)
        await waitUntil("transfert terminé malgré la fermeture") { model.transfers.items.first?.state == .done }
    }

    func testDeletingAConnectionForgetsItsPassword() {
        let model = makeModel { connection, _ in MockProvider(connection: connection) }
        model.addConnection()
        let id = model.selectedConnectionID!
        try? secrets.save(password: "x", for: id, label: "x")
        model.deleteConnection(id)
        XCTAssertNil(secrets.password(for: id))
        XCTAssertNil(model.selectedConnectionID)
        XCTAssertTrue(model.connections.isEmpty)
    }

    func testLastUsedConnectionIsPreselected() async {
        let model = makeModel { connection, _ in MockProvider(connection: connection) }
        model.addConnection()
        model.addConnection()
        let second = model.selectedConnectionID!
        model.updateConnection(second) { $0.host = "exemple.fr" }
        model.select(model.connections[0].id)
        model.select(second)
        model.connect()
        await waitUntil("navigation") { model.phase.isBrowsing }
        let reopened = makeModel { connection, _ in MockProvider(connection: connection) }
        XCTAssertEqual(reopened.selectedConnectionID, second)
    }
}

/// Ce que la sonde a reçu, lisible depuis le fil principal.
final class ProbeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(connection: RemoteConnection, password: String)] = []
    func record(_ connection: RemoteConnection, _ password: String) { lock.withLock { entries.append((connection, password)) } }
    var calls: [(connection: RemoteConnection, password: String)] { lock.withLock { entries } }
}

@MainActor
final class FTPSOfferTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var secrets: MemorySecretStore!
    private var log: ProbeLog!
    private var openedProtocols: [RemoteProtocol] = []

    override func setUp() async throws {
        suite = "FilTests.\(Self.self)"
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
        secrets = MemorySecretStore()
        log = ProbeLog()
        openedProtocols = []
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeModel(result: FTPSProbe.Result, delay: Duration = .zero) -> AppModel {
        let log = log!
        return AppModel(
            store: ConnectionStore(defaults: defaults),
            preferences: Preferences(defaults: defaults),
            secrets: secrets,
            makeProvider: { [unowned self] connection, _ in
                MainActor.assumeIsolated { self.openedProtocols.append(connection.protocol) }
                return MockProvider(connection: connection)
            },
            probeFTPS: { connection, password in
                log.record(connection, password)
                if delay > .zero { try? await Task.sleep(for: delay) }
                return result
            }
        )
    }

    private func openConnection(_ model: AppModel, protocol proto: RemoteProtocol) async {
        model.addConnection()
        let id = model.selectedConnectionID!
        model.updateProtocol(id, to: proto)
        model.updateConnection(id) { $0.host = "exemple.fr"; $0.username = "moi" }
        model.passwordDraft = "mdp"
        model.connect()
        await waitUntil("navigation") { model.phase.isBrowsing }
    }

    func testOfferedWhenTheServerAcceptsFTPS() async {
        let model = makeModel(result: .available)
        await openConnection(model, protocol: .ftp)
        await waitUntil("proposition") { model.hasFTPSOffer }

        XCTAssertEqual(log.calls.count, 1)
        XCTAssertEqual(log.calls[0].connection.protocol, .ftp)
        XCTAssertEqual(log.calls[0].password, "mdp", "la sonde se connecte avec le mot de passe de la connexion")
    }

    func testNotOfferedWhenFTPSIsUnavailableOrUntrusted() async {
        for result in [FTPSProbe.Result.unavailable, .untrustedCertificate] {
            log = ProbeLog()
            let model = makeModel(result: result)
            await openConnection(model, protocol: .ftp)
            await waitUntil("sonde lancée") { self.log.calls.count == 1 }
            try? await Task.sleep(for: .milliseconds(60))
            XCTAssertFalse(model.hasFTPSOffer, "\(result) ne doit rien proposer")
        }
    }

    func testOnlyPlainFTPConnectionsAreProbed() async {
        for proto in [RemoteProtocol.sftp, .webdav, .ftps] {
            let model = makeModel(result: .available)
            await openConnection(model, protocol: proto)
            try? await Task.sleep(for: .milliseconds(60))
            XCTAssertFalse(model.hasFTPSOffer, "\(proto.label) n'a pas à passer en FTPS")
            model.closeConnection()
        }
        XCTAssertEqual(log.calls.count, 0)
    }

    func testDismissingIsRememberedForThisServer() async {
        let model = makeModel(result: .available)
        await openConnection(model, protocol: .ftp)
        await waitUntil("proposition") { model.hasFTPSOffer }

        model.dismissFTPSOffer()
        XCTAssertFalse(model.hasFTPSOffer)
        XCTAssertEqual(ConnectionStore(defaults: defaults).load().connections.first?.ftpsOfferDismissed, true)

        model.closeConnection()
        model.connect()
        await waitUntil("navigation") { model.phase.isBrowsing }
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(log.calls.count, 1, "on ne sonde plus un serveur dont l'utilisateur ne veut pas")
        XCTAssertFalse(model.hasFTPSOffer)
    }

    func testAcceptingSwitchesTheProtocolAndReconnectsEncrypted() async {
        let model = makeModel(result: .available)
        await openConnection(model, protocol: .ftp)
        await waitUntil("proposition") { model.hasFTPSOffer }
        let id = model.selectedConnectionID!

        model.acceptFTPSOffer()
        await waitUntil("reconnecté en FTPS") { model.phase.isBrowsing && self.openedProtocols.count == 2 }

        XCTAssertEqual(model.connections.first { $0.id == id }?.protocol, .ftps)
        XCTAssertEqual(model.connections.first { $0.id == id }?.port, 21, "le port ne bouge pas")
        XCTAssertEqual(openedProtocols, [.ftp, .ftps])
        XCTAssertFalse(model.hasFTPSOffer)
        XCTAssertEqual(ConnectionStore(defaults: defaults).load().connections.first?.protocol, .ftps, "le choix est enregistré")
        XCTAssertEqual(log.calls.count, 1, "une connexion FTPS n'est plus sondée")
    }

    func testLeavingBeforeTheProbeAnswersShowsNothing() async {
        let model = makeModel(result: .available, delay: .milliseconds(150))
        await openConnection(model, protocol: .ftp)
        model.closeConnection()
        try? await Task.sleep(for: .milliseconds(320))
        XCTAssertFalse(model.hasFTPSOffer)
        XCTAssertNil(model.ftpsOfferedFor, "une réponse tardive ne ressuscite pas la proposition")
    }

    func testOfferDoesNotFollowToAnotherConnection() async {
        let model = makeModel(result: .available)
        await openConnection(model, protocol: .ftp)
        await waitUntil("proposition") { model.hasFTPSOffer }
        model.addConnection()
        XCTAssertFalse(model.hasFTPSOffer)
    }
}
