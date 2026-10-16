import XCTest
@testable import Fil

/// Un certificat jetable (CN=fil-test.example, auto-signé) et son empreinte, calculée par openssl.
enum CertificateVector {
    static let derBase64 = "MIIBjTCCATOgAwIBAgIUfGh0F2x+rkKCUQbbMlWRkVh3GlQwCgYIKoZIzj0EAwIwGzEZMBcGA1UEAwwQZmlsLXRlc3QuZXhhbXBsZTAgFw0yNjEwMTMxMDIxMDRaGA8yMTI2MDkxOTEwMjEwNFowGzEZMBcGA1UEAwwQZmlsLXRlc3QuZXhhbXBsZTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABIKnptqJx4uOMx60NIKOnSNfKveMitYKFG9hPqPDqo6n4S+vm/HqEEWgG6TTwAAc4bI6rtGhBlwTVQXoMVXDqoijUzBRMB0GA1UdDgQWBBRyHG96+hvSzSfAx0sMi6uZMYgl1zAfBgNVHSMEGDAWgBRyHG96+hvSzSfAx0sMi6uZMYgl1zAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIQCzQ/CZ83edgZKaKvBnWCqDVz9+ANaXzmrR/mlk4y3RcQIgZAIWEM1f8RUcAbT/c6K57vWNznZ06truAH07KIq0M6c="
    static let sha256 = "eb9ecfca91fc616c435510146345415960f9a90a2cdf92760ab3f87951fb725f"
    static var der: Data { Data(base64Encoded: derBase64)! }
}

final class HostKeyTests: XCTestCase {
    /// Une clé d'hôte de test et son empreinte, telle que l'affiche `ssh-keygen -l`.
    private let line = "[127.0.0.1]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMWXZhRKmQ8Idwe+BXrldEX/0ncIT9Tdc0u+i4v3c6YK"
    private let expected = "SHA256:vX8/1VhscKUn/5u204tIY3LisCfLuv1p22aWLfowa5k"

    func testFingerprintMatchesSSHKeygen() throws {
        let key = try XCTUnwrap(HostKey(knownHostsLine: line))
        XCTAssertEqual(key.fingerprint, expected)
        XCTAssertEqual(key.type, "ssh-ed25519")
        XCTAssertEqual(key.typeLabel, "ED25519")
        XCTAssertEqual(key.host, "[127.0.0.1]:2222")
        XCTAssertEqual(key.line, line)
    }

    func testCommentsAndMarkersAreNotKeysToTrust() {
        XCTAssertNil(HostKey(knownHostsLine: ""))
        XCTAssertNil(HostKey(knownHostsLine: "# un commentaire"))
        XCTAssertNil(HostKey(knownHostsLine: "@revoked h ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMWXZhRKmQ8Idwe+BXrldEX/0ncIT9Tdc0u+i4v3c6YK"))
        XCTAssertNil(HostKey(knownHostsLine: "@cert-authority * ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMWXZhRKmQ8Idwe+BXrldEX/0ncIT9Tdc0u+i4v3c6YK"))
        XCTAssertNil(HostKey(knownHostsLine: "h ssh-ed25519 pas-du-base64!"), "une clé illisible n'est jamais montrée comme valide")
        XCTAssertNil(HostKey(knownHostsLine: "h ssh-ed25519"))
    }

    func testHashedHostsAndTrailingCommentAreKeptApart() throws {
        let hashed = try XCTUnwrap(HostKey(knownHostsLine: "|1|c2FsdA==|aGFzaA== ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMWXZhRKmQ8Idwe+BXrldEX/0ncIT9Tdc0u+i4v3c6YK mon-commentaire"))
        XCTAssertEqual(hashed.host, "|1|c2FsdA==|aGFzaA==")
        XCTAssertEqual(hashed.fingerprint, expected)
        XCTAssertFalse(hashed.line.contains("mon-commentaire"), "seule la clé est retenue")
    }

    func testKeyTypeLabels() {
        func label(_ type: String) -> String { HostKey(host: "h", type: type, fingerprint: "f", line: "l").typeLabel }
        XCTAssertEqual(label("ecdsa-sha2-nistp256"), "ECDSA")
        XCTAssertEqual(label("ssh-rsa"), "RSA")
        XCTAssertEqual(label("inconnu"), "inconnu")
    }
}

final class CertificateInfoTests: XCTestCase {
    func testReadsASelfSignedCertificate() throws {
        let info = try XCTUnwrap(CertificateInfo(der: CertificateVector.der))
        XCTAssertEqual(info.sha256, CertificateVector.sha256, "même empreinte qu'openssl")
        XCTAssertEqual(info.subject, "fil-test.example")
        XCTAssertTrue(info.isSelfSigned)
        let expiry = try XCTUnwrap(info.notAfter)
        XCTAssertEqual(Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: expiry).year, 2126)
    }

    func testFingerprintIsGroupedLikeServersShowIt() {
        XCTAssertEqual(CertificateInfo.grouped("a0fa084e"), "A0:FA:08:4E")
        let info = CertificateInfo(sha256: "a0fa084e", subject: "s", isSelfSigned: true, notAfter: nil, der: Data())
        XCTAssertEqual(info.fingerprint, "A0:FA:08:4E")
        XCTAssertEqual(TrustedCertificate(sha256: "a0fa", subject: "s").fingerprint, "A0:FA")
    }

    func testTheFingerprintIsShownOnTwoLinesCutBetweenBytes() throws {
        let info = try XCTUnwrap(CertificateInfo(der: CertificateVector.der))
        XCTAssertEqual(info.fingerprintLines.count, 2)
        XCTAssertEqual(info.fingerprintLines.map { $0.split(separator: ":").count }, [16, 16])
        XCTAssertEqual(info.fingerprintLines.joined(separator: ":"), info.fingerprint, "rien ne se perd à la coupure")
        XCTAssertEqual(CertificateInfo(sha256: "a0fa08", subject: "s", isSelfSigned: true, notAfter: nil, der: Data()).fingerprintLines, ["A0:FA:08"])
    }

    func testGarbageIsNotACertificate() {
        XCTAssertNil(CertificateInfo(der: Data("pas un certificat".utf8)))
    }
}

final class TrustStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try makeTemporaryFolder()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private let key = HostKey(knownHostsLine: "[h]:22 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMWXZhRKmQ8Idwe+BXrldEX/0ncIT9Tdc0u+i4v3c6YK")!

    func testKnownHostsAreAppendedOnceAndPrivate() throws {
        let store = FilKnownHosts(url: folder.appendingPathComponent("support/known_hosts"))
        try store.trust([key])
        try store.trust([key])
        let text = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertEqual(text, key.line + "\n", "une seule ligne, retour à la ligne final")
        let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        let folderPermissions = try FileManager.default.attributesOfItem(atPath: store.url.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(folderPermissions, 0o700)
    }

    func testAnExistingFileWithoutFinalNewlineIsRespected() throws {
        let url = folder.appendingPathComponent("known_hosts")
        try "autre ssh-rsa AAAA".write(to: url, atomically: true, encoding: .utf8)
        try FilKnownHosts(url: url).trust([key])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "autre ssh-rsa AAAA\n" + key.line + "\n")
    }

    func testPinnedCertificateIsWrittenAsPEM() throws {
        let store = PinnedCertificates(folder: folder.appendingPathComponent("certificates"))
        let info = try XCTUnwrap(CertificateInfo(der: CertificateVector.der))
        XCTAssertNil(store.pemURL(for: info.sha256))
        try store.save(info)

        let url = try XCTUnwrap(store.pemURL(for: info.sha256))
        let pem = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(pem.hasPrefix("-----BEGIN CERTIFICATE-----\n"))
        XCTAssertTrue(pem.hasSuffix("-----END CERTIFICATE-----\n"))
        let body = pem.split(separator: "\n").dropFirst().dropLast()
        XCTAssertTrue(body.allSatisfy { $0.count <= 64 }, "lignes de 64 caractères au plus")
        XCTAssertEqual(Data(base64Encoded: body.joined()), CertificateVector.der)

        store.remove(info.sha256)
        XCTAssertNil(store.pemURL(for: info.sha256))
    }
}

final class SSHTrustCommandTests: XCTestCase {
    private let connection = RemoteConnection(host: "exemple.fr", port: 2222, protocol: .sftp, username: "moi")

    func testRealConnectionReadsFilsFileInAdditionToTheUsers() {
        let trusted = URL(fileURLWithPath: "/Users/moi/Library/Application Support/Fil/known_hosts")
        let arguments = SSHCommand.arguments(for: connection, trustedHosts: trusted)
        let option = arguments.first { $0.hasPrefix("GlobalKnownHostsFile=") }
        XCTAssertEqual(option, "GlobalKnownHostsFile=\"/etc/ssh/ssh_known_hosts\" \"/etc/ssh/ssh_known_hosts2\" \"/Users/moi/Library/Application Support/Fil/known_hosts\"", "chemin cité : il contient une espace")
        XCTAssertFalse(arguments.contains { $0.hasPrefix("UserKnownHostsFile") }, "le fichier de l'utilisateur est laissé à sa configuration")
    }

    func testAPathThatCannotBeQuotedIsIgnoredRatherThanMisread() {
        let arguments = SSHCommand.arguments(for: connection, trustedHosts: URL(fileURLWithPath: "/tmp/a\"b/known_hosts"))
        XCTAssertFalse(arguments.contains { $0.hasPrefix("GlobalKnownHostsFile") })
    }

    func testDiscoveryNeverAuthenticatesAndNeverTouchesTheUsersFiles() {
        let scratch = URL(fileURLWithPath: "/tmp/fil-hostkey/known_hosts")
        let arguments = SSHCommand.discoveryArguments(for: connection, extraOptions: ["-o", "UserKnownHostsFile=/Users/moi/.ssh/known_hosts"], knownHostsFile: scratch)
        XCTAssertEqual(arguments.suffix(3), ["--", "exemple.fr", "true"], "aucune session SFTP : on relève la clé et on s'arrête")
        for option in ["PreferredAuthentications=none", "BatchMode=yes", "StrictHostKeyChecking=accept-new", "GlobalKnownHostsFile=/dev/null", "UpdateHostKeys=no"] {
            XCTAssertTrue(arguments.contains(option), option)
        }
        // `ssh` garde la première valeur d'une option : celle de la sonde doit précéder toute autre.
        let ours = arguments.firstIndex(of: "UserKnownHostsFile=\(scratch.path)")
        let theirs = arguments.firstIndex(of: "UserKnownHostsFile=/Users/moi/.ssh/known_hosts")
        XCTAssertNotNil(ours)
        XCTAssertTrue(ours! < theirs!)
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-p")! + 1], "2222")
    }

    func testUnknownAndChangedServersAreTold() {
        func describe(_ text: String) -> ProviderError { SSHCommand.describeExit(status: 255, errorOutput: text, host: "h", port: 22) }
        XCTAssertEqual(describe("No ED25519 host key is known for [127.0.0.1]:2222 and you have requested strict checking.\nHost key verification failed."), .hostKeyUnknown([]))
        XCTAssertEqual(describe("@@@@\nWARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\nHost key verification failed."), .hostKeyChanged("h"))
        XCTAssertEqual(describe("Host key verification failed."), .hostKeyChanged("h"), "dans le doute, on refuse")
        XCTAssertEqual(describe("debug1: Server host key: ssh-ed25519 SHA256:abc\ndebug1: Trying private key").isInterruption, true, "du bruit de débogage n'est pas un message")
    }
}

/// Le parcours de confiance de bout en bout côté modèle, avec un fournisseur simulé.
@MainActor
final class TrustFlowTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var attempts = 0

    private let key = HostKey(knownHostsLine: "[exemple.fr]:22 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMWXZhRKmQ8Idwe+BXrldEX/0ncIT9Tdc0u+i4v3c6YK")!

    override func setUp() async throws {
        suite = "FilTests.\(Self.self)"
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
        folder = try makeTemporaryFolder()
        attempts = 0
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    private var knownHosts: FilKnownHosts { FilKnownHosts(url: folder.appendingPathComponent("known_hosts")) }
    private var certificates: PinnedCertificates { PinnedCertificates(folder: folder.appendingPathComponent("certificates")) }

    /// La première tentative échoue avec `firstError`, les suivantes réussissent.
    private func makeModel(firstError: Error?) -> AppModel {
        AppModel(
            store: ConnectionStore(defaults: defaults),
            preferences: Preferences(defaults: defaults),
            secrets: MemorySecretStore(),
            makeProvider: { [unowned self] connection, _ in
                MainActor.assumeIsolated { self.attempts += 1 }
                let first = MainActor.assumeIsolated { self.attempts == 1 }
                return MockProvider(connection: connection, connectError: first ? firstError : nil)
            },
            knownHosts: knownHosts,
            certificates: certificates,
            probeFTPS: { _, _ in .unavailable }
        )
    }

    private func start(_ model: AppModel, protocol proto: RemoteProtocol) async {
        model.addConnection()
        let id = model.selectedConnectionID!
        model.updateProtocol(id, to: proto)
        model.updateConnection(id) { $0.host = "exemple.fr"; $0.username = "moi" }
        model.passwordDraft = "mdp"
        model.connect()
    }

    func testAnUnknownSSHServerAsksBeforeConnecting() async throws {
        let model = makeModel(firstError: ProviderError.hostKeyUnknown([key]))
        await start(model, protocol: .sftp)
        await waitUntil("confirmation demandée") { model.phase.isConfirming }

        guard case .confirming(let connection, .hostKey(let keys)) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(keys, [key])
        XCTAssertEqual(connection.host, "exemple.fr")
        XCTAssertFalse(FileManager.default.fileExists(atPath: knownHosts.url.path), "rien n'est enregistré avant l'accord")
        XCTAssertEqual(attempts, 1)

        model.confirmTrust()
        await waitUntil("connecté après accord") { model.phase.isBrowsing }
        XCTAssertEqual(try String(contentsOf: knownHosts.url, encoding: .utf8), key.line + "\n")
        XCTAssertEqual(attempts, 2)
    }

    func testDecliningConnectsNothingAndRemembersNothing() async {
        let model = makeModel(firstError: ProviderError.hostKeyUnknown([key]))
        await start(model, protocol: .sftp)
        await waitUntil("confirmation demandée") { model.phase.isConfirming }

        model.declineTrust()
        XCTAssertEqual(model.phase, .choosing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: knownHosts.url.path))
        XCTAssertEqual(attempts, 1)
    }

    func testAnUnknownServerWithoutKeysIsAnErrorNotAConfirmation() async {
        let model = makeModel(firstError: ProviderError.hostKeyUnknown([]))
        await start(model, protocol: .sftp)
        await waitUntil("échec") { if case .failed = model.phase { true } else { false } }
        guard case .failed(_, let reason) = model.phase else { return XCTFail() }
        XCTAssertEqual(reason, "Fil ne connaît pas encore ce serveur. Vérifie son empreinte avant de lui faire confiance.")
    }

    func testAnUntrustedCertificateIsPinnedAfterConfirmation() async throws {
        let info = try XCTUnwrap(CertificateInfo(der: CertificateVector.der))
        let model = makeModel(firstError: ProviderError.certificateToConfirm(info))
        await start(model, protocol: .ftps)
        await waitUntil("confirmation demandée") { model.phase.isConfirming }
        guard case .confirming(_, .certificate(let shown)) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(shown, info)
        XCTAssertNil(model.selectedConnection?.trustedCertificate)

        model.confirmTrust()
        await waitUntil("connecté après accord") { model.phase.isBrowsing }
        let pinned = try XCTUnwrap(model.selectedConnection?.trustedCertificate)
        XCTAssertEqual(pinned, TrustedCertificate(sha256: CertificateVector.sha256, subject: "fil-test.example"))
        XCTAssertNotNil(certificates.pemURL(for: CertificateVector.sha256), "le certificat est rangé pour libcurl")
        XCTAssertEqual(ConnectionStore(defaults: defaults).load().connections.first?.trustedCertificate, pinned, "l'approbation survit au redémarrage")
    }

    func testForgettingACertificateRemovesItsFileUnlessAnotherConnectionStillUsesIt() async throws {
        let info = try XCTUnwrap(CertificateInfo(der: CertificateVector.der))
        let model = makeModel(firstError: nil)
        try certificates.save(info)
        model.addConnection()
        let first = model.selectedConnectionID!
        model.addConnection()
        let second = model.selectedConnectionID!
        let pin = TrustedCertificate(sha256: info.sha256, subject: info.subject)
        model.updateConnection(first) { $0.trustedCertificate = pin }
        model.updateConnection(second) { $0.trustedCertificate = pin }

        model.forgetCertificate(first)
        XCTAssertNil(model.connections.first { $0.id == first }?.trustedCertificate)
        XCTAssertNotNil(certificates.pemURL(for: info.sha256), "l'autre connexion s'en sert encore")
        model.forgetCertificate(second)
        XCTAssertNil(certificates.pemURL(for: info.sha256))
    }

    func testTrustDoesNotFollowAnotherAddress() throws {
        let model = makeModel(firstError: nil)
        model.addConnection()
        let id = model.selectedConnectionID!
        model.updateProtocol(id, to: .webdav)
        model.updateConnection(id) { $0.host = "nas.local"; $0.trustedCertificate = TrustedCertificate(sha256: "ab", subject: "nas") }

        model.updateConnection(id) { $0.name = "Mon NAS" }
        XCTAssertNotNil(model.selectedConnection?.trustedCertificate, "renommer ne change pas de serveur")
        model.updateConnection(id) { $0.username = "autre" }
        XCTAssertNotNil(model.selectedConnection?.trustedCertificate)
        model.updateConnection(id) { $0.host = "autre-nas.local" }
        XCTAssertNil(model.selectedConnection?.trustedCertificate, "une autre adresse est un autre serveur")
    }

    func testChoosingAnotherConnectionLeavesTheConfirmationPage() async {
        let model = makeModel(firstError: ProviderError.hostKeyUnknown([key]))
        await start(model, protocol: .sftp)
        await waitUntil("confirmation demandée") { model.phase.isConfirming }
        let other = RemoteConnection(name: "Autre", host: "autre.fr")
        model.connections.append(other)
        model.select(other.id)
        XCTAssertEqual(model.phase, .choosing)
    }

    func testConfirmingPhaseExposesItsConnection() {
        let connection = RemoteConnection(host: "exemple.fr")
        let phase = Phase.confirming(connection, .hostKey([]))
        XCTAssertEqual(phase.connection, connection)
        XCTAssertTrue(phase.isConfirming)
        XCTAssertFalse(phase.isConnecting)
        XCTAssertFalse(phase.isBrowsing)
    }

    func testOldFavoritesDecodeWithoutACertificate() throws {
        let legacy = #"{"id":"7B1F7C55-2F0F-4D1B-9B53-3D3A5A1E8C11","name":"Ancien","host":"h","port":443,"protocol":"webdav","username":"u"}"#
        XCTAssertNil(try JSONDecoder().decode(RemoteConnection.self, from: Data(legacy.utf8)).trustedCertificate)
        let pinned = RemoteConnection(host: "h", protocol: .webdav, trustedCertificate: TrustedCertificate(sha256: "ab", subject: "s"))
        let decoded = try JSONDecoder().decode(RemoteConnection.self, from: JSONEncoder().encode(pinned))
        XCTAssertEqual(decoded.trustedCertificate, pinned.trustedCertificate)
    }
}

final class FTPReplyTests: XCTestCase {
    func testASingleLineReplyEndsWithCRLF() {
        // Régression : `"…\r\n".hasSuffix("\n")` est faux en Swift, la lecture attendait la fin pour rien.
        XCTAssertTrue(CertificateReader.isCompleteReply("220 pyftpdlib 2.2.0 ready.\r\n"))
        XCTAssertTrue(CertificateReader.isCompleteReply("234 AUTH TLS successful.\r\n"))
        XCTAssertTrue(CertificateReader.isCompleteReply("220 prêt\n"), "un serveur qui n'envoie que LF")
    }

    func testAMultilineReplyIsCompleteOnlyAtItsLastLine() {
        XCTAssertFalse(CertificateReader.isCompleteReply("220-Bienvenue\r\n"))
        XCTAssertFalse(CertificateReader.isCompleteReply("220-Bienvenue\r\n  suite libre\r\n"))
        XCTAssertTrue(CertificateReader.isCompleteReply("220-Bienvenue\r\n  suite libre\r\n220 Fin.\r\n"))
    }

    func testAPartialLineIsNotAReply() {
        XCTAssertFalse(CertificateReader.isCompleteReply(""))
        XCTAssertFalse(CertificateReader.isCompleteReply("220 pyftp"))
        XCTAssertFalse(CertificateReader.isCompleteReply("22"))
        XCTAssertFalse(CertificateReader.isCompleteReply("\r\n"))
        XCTAssertFalse(CertificateReader.isCompleteReply("pas un code\r\n"))
    }
}
