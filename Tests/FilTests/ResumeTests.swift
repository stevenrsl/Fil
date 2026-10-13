import XCTest
@testable import Fil

/// Envoi atomique, reprise et leurs garde-fous, contre un serveur simulé qui impose les mêmes
/// préconditions qu'un vrai (décalage exact) et tombe en panne à la demande.
@MainActor
final class AtomicUploadAndResumeTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = try makeTemporaryFolder()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func source(_ name: String, _ text: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func isFailed(_ queue: TransferQueue) -> Bool {
        if case .failed = queue.items.first?.state { return true }
        return false
    }

    // MARK: Envoi atomique

    func testNewVersionAppearsOnlyOnceComplete() async throws {
        let provider = MockProvider(files: ["/site/index.html": "ancienne version"])
        await provider.set(chunkDelay: .milliseconds(3))
        let text = String(repeating: "N", count: 80)
        let queue = TransferQueue()

        queue.upload([try source("index.html", text)], into: RemotePath("/site"), via: provider)
        await waitUntil("partiel en cours") { (await provider.contents[RemotePath("/site/index.html.filpart")]?.count ?? 0) > 0 }
        // En plein envoi : la version en ligne n'a pas bougé pendant que le partiel grandit à côté.
        let during = await provider.contents[RemotePath("/site/index.html")]
        XCTAssertEqual(during, Data("ancienne version".utf8))

        await waitUntil("envoi terminé") { queue.items.first?.state == .done }
        let contents = await provider.contents
        XCTAssertEqual(contents[RemotePath("/site/index.html")], Data(text.utf8))
        XCTAssertNil(contents[RemotePath("/site/index.html.filpart")])
        let journal = await provider.journal
        XCTAssertEqual(journal, ["upload /site/index.html.filpart from 0", "move /site/index.html.filpart -> /site/index.html"])
    }

    func testAnInterruptionLeavesTheOnlineVersionUntouched() async throws {
        let provider = MockProvider(files: ["/site/index.html": "ancienne version"])
        await provider.set(interruptAfter: 40)
        let queue = TransferQueue()

        queue.upload([try source("index.html", String(repeating: "x", count: 100))], into: RemotePath("/site"), via: provider)
        await waitUntil("échec") { self.isFailed(queue) }

        let contents = await provider.contents
        XCTAssertEqual(contents[RemotePath("/site/index.html")], Data("ancienne version".utf8))
        XCTAssertEqual(contents[RemotePath("/site/index.html.filpart")]?.count, 40)
        XCTAssertEqual(queue.items[0].state, .failed("La connexion au serveur s'est interrompue."))
        XCTAssertEqual(queue.items[0].resumeNote?.hasPrefix("Réessayer reprend"), true)
    }

    // MARK: Reprise d'un envoi

    func testInterruptedUploadResumesWhereItStopped() async throws {
        let provider = MockProvider(files: ["/site/index.html": "ancienne version"])
        let text = String(repeating: "abcdefghij", count: 10)
        await provider.set(interruptAfter: 40)
        let queue = TransferQueue()

        queue.upload([try source("index.html", text)], into: RemotePath("/site"), via: provider)
        await waitUntil("échec") { self.isFailed(queue) }
        queue.retry(queue.items[0].id)
        await waitUntil("repris et terminé") { queue.items.first?.state == .done }

        let journal = await provider.journal
        XCTAssertEqual(journal, [
            "upload /site/index.html.filpart from 0",
            "upload /site/index.html.filpart from 40",
            "move /site/index.html.filpart -> /site/index.html"
        ])
        let final = await provider.contents[RemotePath("/site/index.html")]
        XCTAssertEqual(final, Data(text.utf8), "le contenu repris est identique à la source")
        XCTAssertEqual(queue.items[0].resumedFrom, 40)
    }

    func testResumeIsRefusedWhenTheSourceChangedBetweenAttempts() async throws {
        let provider = MockProvider(files: ["/site/index.html": "ancienne version"])
        await provider.set(interruptAfter: 40)
        let queue = TransferQueue()
        let url = try source("index.html", String(repeating: "A", count: 100))

        queue.upload([url], into: RemotePath("/site"), via: provider)
        await waitUntil("échec") { self.isFailed(queue) }
        let edited = String(repeating: "B", count: 120)
        try edited.write(to: url, atomically: true, encoding: .utf8)
        queue.retry(queue.items[0].id)
        await waitUntil("terminé") { queue.items.first?.state == .done }

        let journal = await provider.journal
        XCTAssertEqual(Array(journal.dropLast()), ["upload /site/index.html.filpart from 0", "upload /site/index.html.filpart from 0"])
        let final = await provider.contents[RemotePath("/site/index.html")]
        XCTAssertEqual(final, Data(edited.utf8), "aucun octet de l'ancienne source ne survit")
    }

    func testAStalePartialFromAnotherSessionIsNeverResumed() async throws {
        // Un `.filpart` du même nom, déjà sur le serveur : Fil ne l'a pas écrit pendant cette session.
        let provider = MockProvider(files: ["/site/page.html.filpart": "RESTE D'UNE AUTRE VERSION"])
        let text = "contenu complet et neuf"
        let queue = TransferQueue()

        queue.upload([try source("page.html", text)], into: RemotePath("/site"), via: provider)
        await waitUntil("terminé") { queue.items.first?.state == .done }

        let journal = await provider.journal
        XCTAssertEqual(journal.first, "upload /site/page.html.filpart from 0")
        let final = await provider.contents[RemotePath("/site/page.html")]
        XCTAssertEqual(final, Data(text.utf8))
    }

    func testAServerThatCannotResumeStartsOver() async throws {
        let provider = MockProvider(files: ["/site/a.txt": "o"], canResumeUploads: false)
        await provider.set(interruptAfter: 30)
        let queue = TransferQueue()
        let text = String(repeating: "z", count: 90)

        queue.upload([try source("a.txt", text)], into: RemotePath("/site"), via: provider)
        await waitUntil("échec") { self.isFailed(queue) }
        queue.retry(queue.items[0].id)
        await waitUntil("terminé") { queue.items.first?.state == .done }

        let journal = await provider.journal
        XCTAssertEqual(journal.filter { $0.hasPrefix("upload") }, ["upload /site/a.txt.filpart from 0", "upload /site/a.txt.filpart from 0"])
        let final = await provider.contents[RemotePath("/site/a.txt")]
        XCTAssertEqual(final, Data(text.utf8))
    }

    // MARK: Vérification avant publication

    func testAShortFileIsNeverPublishedOverTheOldOne() async throws {
        let provider = MockProvider(files: ["/site/gros.bin": "ancienne version"])
        await provider.set(chunkSize: 1 << 20)
        await provider.set(dropLastUploadedByte: true)
        let size = Int(TransferRunner.verificationThreshold) + 10
        let queue = TransferQueue()
        let url = folder.appendingPathComponent("gros.bin")
        try Data(repeating: 0x61, count: size).write(to: url)

        queue.upload([url], into: RemotePath("/site"), via: provider)
        await waitUntil("refusé") { self.isFailed(queue) }

        guard case .failed(let reason) = queue.items[0].state else { return XCTFail() }
        XCTAssertTrue(reason.contains("n'est arrivé qu'en partie"), reason)
        let contents = await provider.contents
        XCTAssertEqual(contents[RemotePath("/site/gros.bin")], Data("ancienne version".utf8), "l'ancienne version est intacte")
        let journal = await provider.journal
        XCTAssertFalse(journal.contains { $0.hasPrefix("move") }, "aucun renommage n'a eu lieu")

        // Le serveur « se reprend » : le partiel (trop court d'un octet) est complété, puis publié.
        await provider.set(dropLastUploadedByte: false)
        queue.retry(queue.items[0].id)
        await waitUntil("repris") { queue.items.first?.state == .done }
        let after = await provider.contents[RemotePath("/site/gros.bin")]
        XCTAssertEqual(after?.count, size)
        let resumes = await provider.journal.filter { $0.hasSuffix("from \(size - 1)") }
        XCTAssertEqual(resumes.count, 1)
    }

    // MARK: Renommage refusé

    func testServerThatRefusesRenamingFallsBackToDirectUpload() async throws {
        let provider = MockProvider(files: ["/depot/.keep": ""])
        await provider.set(refuseMove: true)
        let queue = TransferQueue()

        queue.upload([try source("a.txt", "premier")], into: RemotePath("/depot"), via: provider)
        await waitUntil("premier terminé") { queue.items.first?.state == .done }
        var contents = await provider.contents
        XCTAssertEqual(contents[RemotePath("/depot/a.txt")], Data("premier".utf8))
        XCTAssertEqual(queue.items[0].notice, "envoi direct : ce serveur refuse le renommage")
        XCTAssertTrue(queue.items[0].phrase(now: .now).contains("envoi direct"))
        await waitUntil("partiel retiré") { await provider.contents[RemotePath("/depot/a.txt.filpart")] == nil }

        // Le serveur est mémorisé : le fichier suivant part tout de suite sous son nom final.
        queue.upload([try source("b.txt", "second")], into: RemotePath("/depot"), via: provider)
        await waitUntil("second terminé") { queue.items.count == 2 && queue.items[1].state == .done }
        let journal = await provider.journal
        XCTAssertEqual(journal.last, "upload /depot/b.txt from 0")
        XCTAssertFalse(journal.contains { $0.contains("b.txt.filpart") })
        contents = await provider.contents
        XCTAssertEqual(contents[RemotePath("/depot/b.txt")], Data("second".utf8))
    }

    // MARK: Annulation et nettoyage

    func testCancellingRemovesTheRemotePartial() async throws {
        let provider = MockProvider(files: ["/site/a.txt": "ancien"])
        await provider.set(chunkDelay: .milliseconds(5))
        let queue = TransferQueue()

        queue.upload([try source("a.txt", String(repeating: "q", count: 200))], into: RemotePath("/site"), via: provider)
        await waitUntil("partiel en cours") { (await provider.contents[RemotePath("/site/a.txt.filpart")]?.count ?? 0) > 0 }
        queue.cancel(queue.items[0].id)
        await waitUntil("annulé") { queue.items.first?.state == .cancelled }
        await waitUntil("partiel distant effacé") { await provider.contents[RemotePath("/site/a.txt.filpart")] == nil }
        let online = await provider.contents[RemotePath("/site/a.txt")]
        XCTAssertEqual(online, Data("ancien".utf8))
    }

    func testClearingAnAbandonedFailureRemovesItsPartials() async throws {
        let provider = MockProvider(files: ["/site/a.txt": "ancien", "/site/lourd.bin": String(repeating: "d", count: 80)])
        await provider.set(interruptAfter: 20)
        let queue = TransferQueue()

        queue.upload([try source("a.txt", String(repeating: "u", count: 60))], into: RemotePath("/site"), via: provider)
        await waitUntil("envoi en échec") { self.isFailed(queue) }
        let partial = await provider.contents[RemotePath("/site/a.txt.filpart")]
        XCTAssertNotNil(partial, "le partiel attend un éventuel « Réessayer »")

        queue.clearFinished()
        XCTAssertTrue(queue.items.isEmpty)
        await waitUntil("partiel distant effacé") { await provider.contents[RemotePath("/site/a.txt.filpart")] == nil }
    }

    // MARK: Reprise d'un téléchargement

    func testInterruptedDownloadResumesFromItsPartial() async throws {
        let text = String(repeating: "0123456789", count: 10)
        let provider = MockProvider(files: ["/big.bin": text])
        await provider.set(interruptAfter: 30)
        let queue = TransferQueue()
        let file = try await provider.list(.root)[0]

        queue.download([file], via: provider, into: folder)
        await waitUntil("échec") { self.isFailed(queue) }
        XCTAssertEqual(LocalFile.size(of: folder.appendingPathComponent("big.bin.filpart")), 30)

        queue.retry(queue.items[0].id)
        await waitUntil("terminé") { queue.items.first?.state == .done }
        let journal = await provider.journal
        XCTAssertEqual(journal, ["download /big.bin from 0", "download /big.bin from 30"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("big.bin"), encoding: .utf8), text)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["big.bin"])
        XCTAssertEqual(queue.items[0].resumedFrom, 30)
    }

    func testDownloadRestartsWhenTheRemoteFileChanged() async throws {
        let provider = MockProvider(files: ["/journal.log": String(repeating: "a", count: 100)])
        await provider.set(interruptAfter: 30)
        let queue = TransferQueue()
        let file = try await provider.list(.root)[0]

        queue.download([file], via: provider, into: folder)
        await waitUntil("échec") { self.isFailed(queue) }
        // Quelqu'un réécrit le fichier, plus court : les 30 octets déjà reçus ne valent plus rien.
        let fresh = String(repeating: "b", count: 40)
        await provider.put("/journal.log", fresh)
        queue.retry(queue.items[0].id)
        await waitUntil("terminé") { queue.items.first?.state == .done }

        let journal = await provider.journal
        XCTAssertEqual(journal, ["download /journal.log from 0", "download /journal.log from 0"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("journal.log"), encoding: .utf8), fresh)
    }

    func testFolderResumeSkipsFinishedFilesAndKeepsTheSameFolder() async throws {
        let provider = MockProvider(files: [
            "/dir/a.txt": String(repeating: "a", count: 10),
            "/dir/b.bin": String(repeating: "b", count: 100),
            "/dir/c.txt": String(repeating: "c", count: 10)
        ])
        // Seul le gros fichier atteint 50 octets : c'est lui qui est coupé.
        await provider.set(interruptAfter: 50)
        let queue = TransferQueue()
        let dir = try await provider.list(.root).first { $0.name == "dir" }!

        queue.download([dir], via: provider, into: folder)
        await waitUntil("échec") { self.isFailed(queue) }
        queue.retry(queue.items[0].id)
        await waitUntil("dossier terminé") { queue.items.first?.state == .done }

        let journal = await provider.journal
        XCTAssertEqual(journal.filter { $0.contains("/dir/a.txt") }.count, 1, "a.txt n'est pas retéléchargé")
        XCTAssertEqual(journal.filter { $0.contains("/dir/c.txt") }.count, 1, "c.txt n'est pas retéléchargé")
        XCTAssertEqual(journal.filter { $0.contains("/dir/b.bin") }, ["download /dir/b.bin from 0", "download /dir/b.bin from 50"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["dir"], "pas de « dir (2) »")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("dir/b.bin"), encoding: .utf8), String(repeating: "b", count: 100))
        XCTAssertEqual(queue.items[0].completedFiles, 3)
    }

    func testFolderUploadResumeSkipsFinishedFiles() async throws {
        let provider = MockProvider(files: ["/site/.keep": ""])
        let source = folder.appendingPathComponent("Projet")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "un".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try String(repeating: "g", count: 100).write(to: source.appendingPathComponent("gros.bin"), atomically: true, encoding: .utf8)
        try "deux".write(to: source.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        await provider.set(interruptAfter: 50)
        let queue = TransferQueue()

        queue.upload([source], into: RemotePath("/site"), via: provider)
        await waitUntil("échec") { self.isFailed(queue) }
        queue.retry(queue.items[0].id)
        await waitUntil("dossier envoyé") { queue.items.first?.state == .done }

        let journal = await provider.journal
        // Un fichier envoyé une fois laisse deux traces (envoi, renommage) : on ne compte que les envois.
        XCTAssertEqual(journal.filter { $0.hasPrefix("upload") && $0.contains("a.txt.filpart") }.count, 1, "a.txt n'est pas renvoyé")
        XCTAssertEqual(journal.filter { $0.hasPrefix("upload") && $0.contains("c.txt.filpart") }.count, 1, "c.txt n'est pas renvoyé")
        XCTAssertEqual(journal.filter { $0.contains("gros.bin.filpart") && $0.hasPrefix("upload") }, ["upload /site/Projet/gros.bin.filpart from 0", "upload /site/Projet/gros.bin.filpart from 50"])
        let contents = await provider.contents
        XCTAssertEqual(Set(contents.keys.map(\.value).filter { $0.hasPrefix("/site/Projet") }), ["/site/Projet/a.txt", "/site/Projet/gros.bin", "/site/Projet/c.txt"])
    }

    func testEndOfSessionRemovesLocalPartials() async throws {
        let provider = MockProvider(files: ["/big.bin": String(repeating: "x", count: 100)])
        await provider.set(interruptAfter: 30)
        let queue = TransferQueue()
        let file = try await provider.list(.root)[0]

        queue.download([file], via: provider, into: folder)
        await waitUntil("échec") { self.isFailed(queue) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["big.bin.filpart"])
        queue.removeLocalPartials()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testARefusalIsNotResumable() async throws {
        let provider = MockProvider(files: ["/site/a.txt": "ancien"])
        await provider.set(transferError: ProviderError.accessDenied("a.txt"))
        let queue = TransferQueue()

        queue.upload([try source("a.txt", "neuf")], into: RemotePath("/site"), via: provider)
        await waitUntil("échec") { self.isFailed(queue) }
        XCTAssertNil(queue.items[0].resumeNote, "un refus du serveur n'est pas une coupure")
        await waitUntil("partiel effacé") { await provider.contents[RemotePath("/site/a.txt.filpart")] == nil }
    }
}

final class ResumeModelTests: XCTestCase {
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    func testPhrasesMentionTheResume() {
        let now = Date()
        var item = TransferItem(direction: .upload, name: "a", isFolder: false, connectionName: "S", remotePath: RemotePath("/a"), localURL: URL(fileURLWithPath: "/tmp/a"), totalBytes: 4_000_000)
        item.state = .running
        item.startedAt = now.addingTimeInterval(-2)
        item.resumedFrom = 2_000_000
        item.transferredBytes = 3_000_000
        // Le débit ne compte que ce qui a été envoyé depuis la reprise : 1 Mo en 2 s.
        XCTAssertEqual(plain(item.phrase(now: now)), "Reprise à 2 Mo · 3 Mo sur 4 Mo · 500 ko/s · encore 2 s")

        item.state = .failed("La connexion au serveur s'est interrompue.")
        item.resumeNote = "Réessayer reprend vers 3 Mo."
        XCTAssertEqual(plain(item.phrase(now: now)), "La connexion au serveur s'est interrompue. Réessayer reprend vers 3 Mo.")

        item.state = .done
        item.notice = "envoi direct : ce serveur refuse le renommage"
        XCTAssertTrue(item.phrase(now: now).hasSuffix(" · envoi direct : ce serveur refuse le renommage"))
    }

    func testIncompleteIsAnInterruptionRefusalsAreNot() {
        let incomplete = ProviderError.incomplete(name: "a.bin", received: 1_000_000, expected: 4_000_000)
        XCTAssertTrue(incomplete.isInterruption)
        XCTAssertEqual(plain(incomplete.errorDescription ?? ""), "« a.bin » n'est arrivé qu'en partie (1 Mo sur 4 Mo).")
        XCTAssertTrue(ProviderError.connectionLost.isInterruption)
        XCTAssertTrue(ProviderError.timedOut.isInterruption)
        XCTAssertFalse(ProviderError.accessDenied("x").isInterruption)
        XCTAssertFalse(ProviderError.authenticationFailed.isInterruption)
        XCTAssertFalse(ProviderError.server("refus").isInterruption)
    }

    @MainActor
    func testInterruptionClassification() {
        XCTAssertTrue(TransferQueue.isInterruption(URLError(.networkConnectionLost)))
        XCTAssertTrue(TransferQueue.isInterruption(ProviderError.connectionLost))
        XCTAssertFalse(TransferQueue.isInterruption(URLError(.badServerResponse)))
        XCTAssertFalse(TransferQueue.isInterruption(CocoaError(.fileWriteOutOfSpace)))
    }

    func testPartialSibling() {
        XCTAssertEqual(RemotePath("/site/index.html").partialSibling.value, "/site/index.html.filpart")
        XCTAssertEqual(RemotePath("/a.txt").partialSibling.value, "/a.txt.filpart")
    }

    func testFTPSOfferFlagSurvivesSavingAndOldFavoritesDecode() throws {
        var connection = RemoteConnection(host: "ftp.exemple.fr", protocol: .ftp)
        XCTAssertFalse(connection.ftpsOfferDismissed)
        connection.ftpsOfferDismissed = true
        let decoded = try JSONDecoder().decode(RemoteConnection.self, from: JSONEncoder().encode(connection))
        XCTAssertTrue(decoded.ftpsOfferDismissed)

        let legacy = #"{"id":"7B1F7C55-2F0F-4D1B-9B53-3D3A5A1E8C11","name":"Ancien","host":"h","port":21,"protocol":"ftp","username":"u"}"#
        XCTAssertFalse(try JSONDecoder().decode(RemoteConnection.self, from: Data(legacy.utf8)).ftpsOfferDismissed)
    }
}

final class MoveReplacingTests: XCTestCase {
    /// Des noms de fichiers, et un renommage qui peut refuser d'écraser ou échouer à placer le nouveau.
    actor Names {
        var files: Set<String>
        var log: [String] = []
        let refusesOverwrite: Bool
        let failsPlacing: Bool

        init(_ files: Set<String>, refusesOverwrite: Bool = false, failsPlacing: Bool = false) {
            self.files = files
            self.refusesOverwrite = refusesOverwrite
            self.failsPlacing = failsPlacing
        }

        func rename(_ from: RemotePath, _ to: RemotePath) throws {
            log.append("rename \(from) -> \(to)")
            guard files.contains(from.value) else { throw ProviderError.notFound(from.name) }
            if refusesOverwrite, files.contains(to.value) { throw ProviderError.server("existe déjà") }
            if failsPlacing, from.value == "/x.part", log.contains(where: { $0.hasSuffix("-> /x.filbak") }) { throw ProviderError.connectionLost }
            files.remove(from.value)
            files.insert(to.value)
        }

        func exists(_ path: RemotePath) -> Bool { files.contains(path.value) }
        func remove(_ path: RemotePath) { log.append("remove \(path)"); files.remove(path.value) }
    }

    private func run(_ names: Names) async throws {
        try await moveReplacing(
            RemotePath("/x.part"), to: RemotePath("/x"),
            rename: { try await names.rename($0, $1) },
            exists: { await names.exists($0) },
            remove: { await names.remove($0) }
        )
    }

    func testDirectRenameWhenTheServerOverwrites() async throws {
        let names = Names(["/x.part", "/x"])
        try await run(names)
        let log = await names.log
        XCTAssertEqual(log, ["rename /x.part -> /x"])
    }

    func testOldFileIsSetAsideWhenTheServerRefusesToOverwrite() async throws {
        let names = Names(["/x.part", "/x"], refusesOverwrite: true)
        try await run(names)
        let log = await names.log
        XCTAssertEqual(log, ["rename /x.part -> /x", "rename /x -> /x.filbak", "rename /x.part -> /x", "remove /x.filbak"])
        let files = await names.files
        XCTAssertEqual(files, ["/x"])
    }

    func testOldFileIsGivenBackWhenThePlacementFails() async throws {
        let names = Names(["/x.part", "/x"], refusesOverwrite: true, failsPlacing: true)
        do {
            try await run(names)
            XCTFail("l'échec doit remonter")
        } catch {
            XCTAssertEqual(error as? ProviderError, .connectionLost)
        }
        let files = await names.files
        XCTAssertEqual(files, ["/x.part", "/x"], "le fichier en ligne est revenu, rien n'est perdu")
    }

    func testAnErrorWithoutAnExistingTargetIsReportedAsIs() async throws {
        let names = Names(["/other"])
        do {
            try await run(names)
            XCTFail("la source est absente")
        } catch {
            XCTAssertEqual(error as? ProviderError, .notFound("x.part"))
        }
        let log = await names.log
        XCTAssertEqual(log, ["rename /x.part -> /x"], "aucune mise de côté inutile")
    }
}

final class FTPSProbeOfflineTests: XCTestCase {
    func testOnlyPlainFTPOnAStandardPortIsProbed() async {
        let sftp = await FTPSProbe.check(RemoteConnection(host: "exemple.fr", protocol: .sftp), password: "")
        XCTAssertEqual(sftp, .unavailable)
        let implicit = await FTPSProbe.check(RemoteConnection(host: "exemple.fr", port: 990, protocol: .ftp), password: "")
        XCTAssertEqual(implicit, .unavailable)
        let alreadyFTPS = await FTPSProbe.check(RemoteConnection(host: "exemple.fr", protocol: .ftps), password: "")
        XCTAssertEqual(alreadyFTPS, .unavailable)
    }
}
