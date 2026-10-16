import XCTest
@testable import Fil

/// Aller-retour complet contre de vrais serveurs locaux, lancés par `Tools/integration-tests.sh`.
/// Sans ces serveurs, les tests sont ignorés.
final class IntegrationTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    private func value(_ key: String) throws -> String {
        guard let value = environment[key], !value.isEmpty else {
            throw XCTSkip("Serveurs de test absents : lance Tools/integration-tests.sh")
        }
        return value
    }

    private func port(_ key: String) throws -> Int {
        let raw = try value(key)
        return try XCTUnwrap(Int(raw))
    }

    // MARK: FTP

    private func ftpConnection(port key: String, protocol proto: RemoteProtocol = .ftp) throws -> RemoteConnection {
        RemoteConnection(name: "IT \(proto.label)", host: "127.0.0.1", port: try port(key), protocol: proto, username: try value("FIL_IT_USER"))
    }

    func testFTPRoundTrip() async throws {
        let provider = FTPProvider(connection: try ftpConnection(port: "FIL_IT_FTP_PORT"), password: try value("FIL_IT_PASSWORD"))
        try await roundTrip(provider)
    }

    func testFTPWithoutMLSDFallsBackToLIST() async throws {
        let provider = FTPProvider(connection: try ftpConnection(port: "FIL_IT_FTP_LEGACY_PORT"), password: try value("FIL_IT_PASSWORD"))
        try await roundTrip(provider)
    }

    func testFTPSRoundTrip() async throws {
        let provider = FTPProvider(
            connection: try ftpConnection(port: "FIL_IT_FTPS_PORT", protocol: .ftps),
            password: try value("FIL_IT_PASSWORD"),
            certificateAuthorities: try value("FIL_IT_FTPS_CA")
        )
        XCTAssertEqual(provider.security, .explicit)
        try await roundTrip(provider)
    }


    func testFTPSOnAPlainServerSaysSo() async throws {
        let provider = FTPProvider(connection: try ftpConnection(port: "FIL_IT_FTP_PORT", protocol: .ftps), password: try value("FIL_IT_PASSWORD"))
        await assertThrows(ProviderError.tlsUnavailable) { _ = try await provider.connect() }
    }

    func testFTPWrongPassword() async throws {
        let provider = FTPProvider(connection: try ftpConnection(port: "FIL_IT_FTP_PORT"), password: "faux")
        await assertThrows(ProviderError.authenticationFailed) { _ = try await provider.connect() }
    }

    func testFTPClosedPort() async throws {
        _ = try value("FIL_IT_FTP_PORT")
        let provider = FTPProvider(connection: RemoteConnection(host: "127.0.0.1", port: 1, protocol: .ftp), password: "")
        await assertThrows(ProviderError.connectionRefused(host: "127.0.0.1", port: 1)) { _ = try await provider.connect() }
    }


    // MARK: Certificats à vérifier

    /// Le certificat « d'un autre serveur » : valide en soi, mais pas celui qu'on a approuvé.
    private func otherCertificate() throws -> CertificateInfo {
        let pem = try String(contentsOfFile: try value("FIL_IT_OTHER_CERT"), encoding: .utf8)
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return try XCTUnwrap(CertificateInfo(der: try XCTUnwrap(Data(base64Encoded: body))))
    }

    private func pinned(_ connection: RemoteConnection, to certificate: CertificateInfo) -> RemoteConnection {
        var connection = connection
        connection.trustedCertificate = TrustedCertificate(sha256: certificate.sha256, subject: certificate.subject)
        return connection
    }

    func testFTPSShowsAnUnknownCertificateThenAcceptsOnlyIt() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PinnedCertificates(folder: folder)
        let connection = try ftpConnection(port: "FIL_IT_FTPS_PORT", protocol: .ftps)
        let password = try value("FIL_IT_PASSWORD")

        // Jamais approuvé : le certificat est montré, la connexion n'a pas eu lieu.
        let certificate: CertificateInfo
        do {
            _ = try await FTPProvider(connection: connection, password: password, pinnedCertificates: store).connect()
            return XCTFail("un certificat inconnu ne doit pas être accepté en silence")
        } catch ProviderError.certificateToConfirm(let presented) {
            certificate = presented
        }
        XCTAssertEqual(certificate.sha256, try value("FIL_IT_FTPS_SHA256"), "même empreinte qu'openssl")
        XCTAssertTrue(certificate.isSelfSigned)
        XCTAssertEqual(certificate.subject, "127.0.0.1")
        XCTAssertNotNil(certificate.notAfter)

        // Approuvé : transferts complets, sans aucune autorité supplémentaire.
        try store.save(certificate)
        try await roundTrip(FTPProvider(connection: pinned(connection, to: certificate), password: password, pinnedCertificates: store))

        // Approuvé, puis le serveur présente autre chose : refus, pas de nouvelle question.
        let other = try otherCertificate()
        try store.save(other)
        let impostor = FTPProvider(connection: pinned(connection, to: other), password: password, pinnedCertificates: store)
        await assertThrows(ProviderError.certificateChanged(host: "127.0.0.1")) { _ = try await impostor.connect() }
    }

    func testWebDAVOverHTTPSShowsAnUnknownCertificateThenAcceptsOnlyIt() async throws {
        let rawRoot = try value("FIL_IT_WEBDAVS_URL")
        let root = try XCTUnwrap(URL(string: rawRoot))
        let base = RemoteConnection(name: "IT WebDAV HTTPS", host: "127.0.0.1", port: 8443, protocol: .webdav, username: try value("FIL_IT_USER"))
        let password = try value("FIL_IT_PASSWORD")

        let certificate: CertificateInfo
        do {
            _ = try await WebDAVProvider(connection: base, password: password, root: root).connect()
            return XCTFail("un certificat inconnu ne doit pas être accepté en silence")
        } catch ProviderError.certificateToConfirm(let presented) {
            certificate = presented
        }
        XCTAssertEqual(certificate.sha256, try value("FIL_IT_WEBDAVS_SHA256"))
        XCTAssertTrue(certificate.isSelfSigned)

        try await roundTrip(WebDAVProvider(connection: pinned(base, to: certificate), password: password, root: root))

        let impostor = WebDAVProvider(connection: pinned(base, to: try otherCertificate()), password: password, root: root)
        await assertThrows(ProviderError.certificateChanged(host: "127.0.0.1")) { _ = try await impostor.connect() }
    }


    // MARK: Modification sur place

    @MainActor func testFTPEditsInPlace() async throws {
        try await editInPlace(FTPProvider(connection: try ftpConnection(port: "FIL_IT_FTP_PORT"), password: try value("FIL_IT_PASSWORD")))
    }

    @MainActor func testSFTPEditsInPlace() async throws {
        try await editInPlace(try sftpProvider())
    }

    @MainActor func testWebDAVEditsInPlace() async throws {
        try await editInPlace(try webDAVProvider())
    }

    /// Ouvrir, enregistrer, se heurter à un changement du serveur, écraser, terminer : sur un vrai serveur.
    @MainActor
    private func editInPlace(_ provider: any RemoteFileProvider, file: StaticString = #filePath, line: UInt = #line) async throws {
        let local = try makeTemporaryFolder()
        let cache = try makeTemporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.removeItem(at: cache)
        }
        let home = try await provider.connect()
        let base = home.appending("fil-edit-\(UUID().uuidString.prefix(8))")
        try await provider.makeDirectory(base)
        let target = base.appending("edit-me.txt")

        func put(_ text: String) async throws {
            let source = local.appendingPathComponent("source-\(UUID().uuidString).txt")
            try text.write(to: source, atomically: true, encoding: .utf8)
            try await provider.upload(source, to: target) { _ in }
        }
        func remoteText() async throws -> String {
            let entry = try await provider.list(base).first { $0.name == "edit-me.txt" }
            let copy = local.appendingPathComponent("lecture-\(UUID().uuidString).txt")
            try await provider.download(try XCTUnwrap(entry), to: copy) { _ in }
            return try String(contentsOf: copy, encoding: .utf8)
        }

        try await put("version 1")
        let coordinator = EditCoordinator(cacheFolder: cache, pollInterval: .milliseconds(30)) { _ in true }
        let entry = try await provider.list(base).first { $0.name == "edit-me.txt" }
        XCTAssertNil(coordinator.start(try XCTUnwrap(entry), via: provider), file: file, line: line)
        await waitUntil("ouvert") { coordinator.sessions.first?.state == .editing }
        let session = try XCTUnwrap(coordinator.sessions.first, file: file, line: line)
        XCTAssertEqual(try String(contentsOf: session.localURL, encoding: .utf8), "version 1", file: file, line: line)

        // Un enregistrement « à la façon des éditeurs » : le fichier est remplacé, pas réécrit.
        try "version 2, plus longue".write(to: session.localURL, atomically: true, encoding: .utf8)
        await waitUntil("envoyé") { coordinator.sessions.first?.syncedAt != nil }
        let afterSave = try await remoteText()
        XCTAssertEqual(afterSave, "version 2, plus longue", file: file, line: line)
        let names = try await provider.list(base).map(\.name)
        XCTAssertFalse(names.contains { $0.hasSuffix(".filpart") }, "aucun partiel après un enregistrement : \(names)", file: file, line: line)

        // Quelqu'un d'autre écrit sur le serveur : l'enregistrement suivant n'écrase rien.
        try await Task.sleep(for: .milliseconds(1_200)) // les dates des serveurs vont à la seconde
        try await put("écrit par quelqu'un d'autre, et nettement plus long que la version 2")
        try "ma version 3".write(to: session.localURL, atomically: true, encoding: .utf8)
        await waitUntil("conflit") { if case .conflict = coordinator.sessions.first?.state { true } else { false } }
        let afterConflict = try await remoteText()
        XCTAssertEqual(afterConflict, "écrit par quelqu'un d'autre, et nettement plus long que la version 2", "rien n'a été écrasé", file: file, line: line)
        XCTAssertEqual(try String(contentsOf: session.localURL, encoding: .utf8), "ma version 3", file: file, line: line)

        coordinator.overwrite(session.id)
        await waitUntil("écrasé après accord") { coordinator.sessions.first?.state == .editing }
        let afterOverwrite = try await remoteText()
        XCTAssertEqual(afterOverwrite, "ma version 3", file: file, line: line)

        await coordinator.finish(session.id)
        XCTAssertTrue(coordinator.sessions.isEmpty, file: file, line: line)
        try await provider.delete(RemoteFile(name: base.name, path: base, kind: .directory))
    }

    // MARK: Sonde FTPS

    func testFTPSProbeRecognisesAnFTPSServer() async throws {
        let result = await FTPSProbe.check(try ftpConnection(port: "FIL_IT_FTPS_PORT"), password: try value("FIL_IT_PASSWORD"), certificateAuthorities: try value("FIL_IT_FTPS_CA"))
        XCTAssertEqual(result, .available)
    }

    func testFTPSProbeDoesNotOfferWhenTheCertificateIsNotTrusted() async throws {
        let result = await FTPSProbe.check(try ftpConnection(port: "FIL_IT_FTPS_PORT"), password: try value("FIL_IT_PASSWORD"))
        XCTAssertEqual(result, .untrustedCertificate)
    }

    func testFTPSProbeOnAPlainServerAndAClosedPort() async throws {
        let plain = await FTPSProbe.check(try ftpConnection(port: "FIL_IT_FTP_PORT"), password: try value("FIL_IT_PASSWORD"))
        XCTAssertEqual(plain, .unavailable)
        let closed = await FTPSProbe.check(RemoteConnection(host: "127.0.0.1", port: 1, protocol: .ftp), password: "")
        XCTAssertEqual(closed, .unavailable)
    }

    // MARK: SFTP

    private func sftpProvider(knownHosts: String? = nil, trustedHosts: URL? = nil) throws -> SFTPProvider {
        let connection = RemoteConnection(name: "IT SFTP", host: "127.0.0.1", port: try port("FIL_IT_SFTP_PORT"), protocol: .sftp, username: try value("FIL_IT_SFTP_USER"))
        return SFTPProvider(connection: connection, extraOptions: [
            "-F", "/dev/null",
            "-i", try value("FIL_IT_SFTP_KEY"),
            "-o", "IdentitiesOnly=yes",
            "-o", "IdentityAgent=none",
            "-o", "UserKnownHostsFile=\(try knownHosts ?? value("FIL_IT_SFTP_KNOWN_HOSTS"))"
        ], trustedHosts: trustedHosts)
    }

    func testSFTPRoundTrip() async throws {
        try await roundTrip(try sftpProvider())
    }


    func testSFTPFirstConnectionShowsTheFingerprintBeforeTrustingIt() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let userFile = folder.appendingPathComponent("known_hosts")
        try Data().write(to: userFile)
        let store = FilKnownHosts(url: folder.appendingPathComponent("fil_known_hosts"))

        // Serveur jamais vu : rien n'est accepté, la clé est relevée pour être vérifiée.
        let first = try sftpProvider(knownHosts: userFile.path, trustedHosts: store.url)
        let keys: [HostKey]
        do {
            _ = try await first.connect()
            return XCTFail("un serveur inconnu ne doit pas être accepté en silence")
        } catch ProviderError.hostKeyUnknown(let found) {
            keys = found
        }
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0].fingerprint, try value("FIL_IT_SFTP_FINGERPRINT"), "même empreinte que ssh-keygen")
        XCTAssertEqual(keys[0].typeLabel, "ED25519")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path), "rien n'est enregistré avant l'accord")
        XCTAssertEqual(try String(contentsOf: userFile, encoding: .utf8), "", "le known_hosts de l'utilisateur n'est jamais touché")

        // Après l'accord : la clé est connue de Fil, et seulement de Fil.
        try store.trust(keys)
        let second = try sftpProvider(knownHosts: userFile.path, trustedHosts: store.url)
        let home = try await second.connect()
        XCTAssertFalse(home.value.isEmpty)
        XCTAssertEqual(try String(contentsOf: userFile, encoding: .utf8), "", "ssh n'écrit rien dans le fichier de l'utilisateur")
    }

    func testSFTPKeyTrustedInFilStillRefusesAnotherKey() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Fil croit connaître ce serveur sous une autre clé que la sienne : refus net, pas une nouvelle question.
        let wrong = try String(contentsOfFile: try value("FIL_IT_SFTP_WRONG_KNOWN_HOSTS"), encoding: .utf8)
        let store = FilKnownHosts(url: folder.appendingPathComponent("fil_known_hosts"))
        try wrong.write(to: store.url, atomically: true, encoding: .utf8)
        let empty = folder.appendingPathComponent("known_hosts")
        try Data().write(to: empty)
        let provider = try sftpProvider(knownHosts: empty.path, trustedHosts: store.url)
        await assertThrows(ProviderError.hostKeyChanged("127.0.0.1")) { _ = try await provider.connect() }
    }

    func testSFTPRefusesAChangedHostKey() async throws {
        // `known_hosts` qui associe au serveur une autre clé que la sienne.
        let provider = try sftpProvider(knownHosts: try value("FIL_IT_SFTP_WRONG_KNOWN_HOSTS"))
        await assertThrows(ProviderError.hostKeyChanged("127.0.0.1")) { _ = try await provider.connect() }
    }

    func testSFTPChannelReopensAfterADrop() async throws {
        let provider = try sftpProvider()
        let home = try await provider.connect()
        await provider.dropChannelForTesting()
        let listing = try await provider.list(home)
        XCTAssertNotNil(listing)
    }

    // MARK: WebDAV

    private func webDAVProvider(password: String? = nil) throws -> WebDAVProvider {
        let connection = RemoteConnection(name: "IT WebDAV", host: "127.0.0.1", protocol: .webdav, username: try value("FIL_IT_USER"))
        let root = try value("FIL_IT_WEBDAV_URL")
        return WebDAVProvider(connection: connection, password: try password ?? value("FIL_IT_PASSWORD"), root: try XCTUnwrap(URL(string: root)))
    }

    func testWebDAVRoundTrip() async throws {
        try await roundTrip(try webDAVProvider())
    }

    func testWebDAVWrongPassword() async throws {
        let provider = try webDAVProvider(password: "faux")
        await assertThrows(ProviderError.authenticationFailed) { _ = try await provider.connect() }
    }

    // MARK: Aller-retour commun

    private func roundTrip(_ provider: any RemoteFileProvider, file: StaticString = #filePath, line: UInt = #line) async throws {
        let local = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: local) }

        let home = try await provider.connect()
        let base = home.appending("fil-it-\(UUID().uuidString.prefix(8))")
        try await provider.makeDirectory(base)
        try await provider.ensureDirectory(base)

        let small = local.appendingPathComponent("été 2026 #1 ; [ok].txt")
        try "bonjour".write(to: small, atomically: true, encoding: .utf8)
        let big = local.appendingPathComponent("gros.bin")
        var bytes = [UInt8](repeating: 0, count: 3_000_123)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        try Data(bytes).write(to: big)

        let progress = ProgressBox()
        try await provider.upload(small, to: base.appending(small.lastPathComponent)) { _ in }
        try await provider.upload(big, to: base.appending("gros.bin")) { progress.record($0) }
        XCTAssertEqual(progress.last, 3_000_123, "progression d'envoi", file: file, line: line)

        let listing = try await provider.list(base)
        XCTAssertEqual(Set(listing.map(\.name)), [small.lastPathComponent, "gros.bin"], file: file, line: line)
        let remoteBig = try XCTUnwrap(listing.first { $0.name == "gros.bin" })
        XCTAssertEqual(remoteBig.byteCount, 3_000_123, file: file, line: line)
        XCTAssertEqual(remoteBig.kind, .file, file: file, line: line)

        let back = local.appendingPathComponent("retour.bin")
        let downloadProgress = ProgressBox()
        try await provider.download(remoteBig, to: back) { downloadProgress.record($0) }
        XCTAssertEqual(try Data(contentsOf: back), Data(bytes), "contenu identique après aller-retour", file: file, line: line)
        XCTAssertEqual(downloadProgress.last, 3_000_123, file: file, line: line)

        let smallBack = local.appendingPathComponent("petit.txt")
        try await provider.download(try XCTUnwrap(listing.first { $0.name == small.lastPathComponent }), to: smallBack) { _ in }
        XCTAssertEqual(try String(contentsOf: smallBack, encoding: .utf8), "bonjour", file: file, line: line)

        // Dossier entier, dans les deux sens, par le même chemin que l'interface.
        let tree = local.appendingPathComponent("Arbre")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try "feuille".write(to: tree.appendingPathComponent("a/b/feuille.txt"), atomically: true, encoding: .utf8)
        try "racine".write(to: tree.appendingPathComponent("racine.txt"), atomically: true, encoding: .utf8)
        let report = TransferReport { _ in }
        try await TransferRunner.upload(tree, into: base, via: provider, ledger: TransferLedger(), report: report)
        let returned = local.appendingPathComponent("Retour", isDirectory: true)
        try FileManager.default.createDirectory(at: returned, withIntermediateDirectories: true)
        try await TransferRunner.download(RemoteFile(name: "Arbre", path: base.appending("Arbre"), kind: .directory), into: returned, via: provider, ledger: TransferLedger(), report: report)
        XCTAssertEqual(try String(contentsOf: returned.appendingPathComponent("Arbre/a/b/feuille.txt"), encoding: .utf8), "feuille", file: file, line: line)

        try await exercisePartialsAndMoves(provider, in: base, local: local, bytes: bytes, remoteBig: remoteBig, file: file, line: line)

        // Annulation en plein transfert : erreur d'annulation, pas d'échec réseau.
        let cancelled = local.appendingPathComponent("annule.bin")
        let holder = TaskHolder()
        let task = Task {
            try await provider.download(remoteBig, to: cancelled) { bytes in
                if bytes > 0 { holder.cancel() }
            }
        }
        holder.task = task
        do {
            try await task.value
            // Un serveur local peut tout livrer avant que l'annulation n'arrive : ce n'est pas une erreur.
        } catch {
            XCTAssertTrue(error is CancellationError, "annulation attendue, reçu \(error)", file: file, line: line)
        }

        do {
            _ = try await provider.list(base.appending("absent"))
            XCTFail("un dossier absent doit échouer", file: file, line: line)
        } catch let error as ProviderError {
            XCTAssertFalse(ReadableError.message(for: error).isEmpty, file: file, line: line)
        }

        try await provider.delete(RemoteFile(name: base.name, path: base, kind: .directory))
        let after = try await provider.list(home)
        XCTAssertFalse(after.contains { $0.path == base }, "suppression récursive", file: file, line: line)
    }

    /// Taille, fichier vide, renommage qui remplace, reprise d'envoi et de téléchargement : octet pour octet.
    private func exercisePartialsAndMoves(_ provider: any RemoteFileProvider, in base: RemotePath, local: URL, bytes: [UInt8], remoteBig: RemoteFile, file: StaticString, line: UInt) async throws {
        let size = try await provider.size(of: base.appending("gros.bin"))
        XCTAssertEqual(size, 3_000_123, "taille d'un fichier présent", file: file, line: line)
        let absent = try await provider.size(of: base.appending("nexistepas.bin"))
        XCTAssertNil(absent, "taille d'un fichier absent", file: file, line: line)

        // Fichier vide, dans les deux sens.
        let empty = local.appendingPathComponent("vide.txt")
        try Data().write(to: empty)
        try await provider.upload(empty, to: base.appending("vide.txt")) { _ in }
        let emptySize = try await provider.size(of: base.appending("vide.txt"))
        XCTAssertEqual(emptySize, 0, "fichier vide envoyé", file: file, line: line)
        let emptyBack = local.appendingPathComponent("vide-retour.txt")
        try await provider.download(RemoteFile(name: "vide.txt", path: base.appending("vide.txt"), kind: .file, byteCount: 0), to: emptyBack) { _ in }
        XCTAssertEqual(try Data(contentsOf: emptyBack), Data(), file: file, line: line)

        // Renommage : vers un nom libre, puis par-dessus un fichier existant.
        for (name, text) in [("ancien.txt", "ancien"), ("nouveau.txt", "le nouveau contenu")] {
            let url = local.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try await provider.upload(url, to: base.appending(name)) { _ in }
        }
        try await provider.move(base.appending("nouveau.txt"), to: base.appending("ancien.txt"))
        let replaced = local.appendingPathComponent("remplace.txt")
        let remoteReplaced = try await provider.list(base).first { $0.name == "ancien.txt" }
        try await provider.download(try XCTUnwrap(remoteReplaced), to: replaced) { _ in }
        XCTAssertEqual(try String(contentsOf: replaced, encoding: .utf8), "le nouveau contenu", "renommage par-dessus l'existant", file: file, line: line)
        let gone = try await provider.size(of: base.appending("nouveau.txt"))
        XCTAssertNil(gone, "la source du renommage a disparu", file: file, line: line)

        // Reprise d'un envoi : un partiel de 1 000 003 octets, complété jusqu'au bout.
        let cut = 1_000_003
        let prefix = local.appendingPathComponent("moitie.bin")
        try Data(bytes.prefix(cut)).write(to: prefix)
        let partial = base.appending("repris.bin.filpart")
        try await provider.upload(prefix, to: partial) { _ in }
        let partialSize = try await provider.size(of: partial)
        XCTAssertEqual(partialSize, Int64(cut), "le partiel est là, à la taille attendue", file: file, line: line)
        let big = local.appendingPathComponent("gros.bin")
        let progress = ProgressBox()
        if provider.canResumeUploads {
            try await provider.upload(big, to: partial, resumingAt: Int64(cut)) { progress.record($0) }
            XCTAssertEqual(progress.last, 3_000_123, "la progression compte depuis le début du fichier", file: file, line: line)
        } else {
            try await provider.upload(big, to: partial) { _ in }
        }
        try await provider.move(partial, to: base.appending("repris.bin"))
        let resumed = try await provider.list(base).first { $0.name == "repris.bin" }
        let resumedBack = local.appendingPathComponent("repris-retour.bin")
        try await provider.download(try XCTUnwrap(resumed), to: resumedBack) { _ in }
        XCTAssertEqual(try Data(contentsOf: resumedBack), Data(bytes), "envoi repris : contenu identique", file: file, line: line)

        // Reprise d'un téléchargement.
        let half = local.appendingPathComponent("telechargement.bin")
        try Data(bytes.prefix(cut)).write(to: half)
        let downloadProgress = ProgressBox()
        try await provider.download(remoteBig, to: half, resumingAt: Int64(cut)) { downloadProgress.record($0) }
        XCTAssertEqual(try Data(contentsOf: half), Data(bytes), "téléchargement repris : contenu identique", file: file, line: line)
        XCTAssertEqual(downloadProgress.last, 3_000_123, file: file, line: line)

        // Le chemin complet, comme l'interface : aucun .filpart ne reste après un envoi.
        let atomic = local.appendingPathComponent("atomique.txt")
        try "contenu".write(to: atomic, atomically: true, encoding: .utf8)
        try await TransferRunner.upload(atomic, into: base, via: provider, ledger: TransferLedger(), report: TransferReport { _ in })
        let names = try await provider.list(base).map(\.name)
        XCTAssertTrue(names.contains("atomique.txt"), file: file, line: line)
        XCTAssertFalse(names.contains { $0.hasSuffix(".filpart") }, "aucun partiel après un envoi réussi : \(names)", file: file, line: line)
    }

    private func assertThrows(_ expected: ProviderError, file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> Void) async {
        do {
            try await work()
            XCTFail("\(expected) attendu", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ProviderError, expected, "reçu : \(error)", file: file, line: line)
        }
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    var last: Int64? { lock.withLock { values.last } }
    func record(_ value: Int64) { lock.withLock { values.append(value) } }
}

private final class TaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Task<Void, Error>?
    var task: Task<Void, Error>? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func cancel() { task?.cancel() }
}
