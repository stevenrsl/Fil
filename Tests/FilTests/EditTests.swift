import XCTest
@testable import Fil

/// Modifier un fichier distant sur place, contre un serveur simulé qui date ses fichiers de façon déterministe.
@MainActor
final class EditCoordinatorTests: XCTestCase {
    private var cache: URL!
    private var opened: [URL] = []
    private var accepts = true
    private var changes: [(UUID, RemotePath)] = []

    override func setUp() async throws {
        cache = try makeTemporaryFolder()
        opened = []
        accepts = true
        changes = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: cache)
    }

    private func makeCoordinator() -> EditCoordinator {
        let coordinator = EditCoordinator(cacheFolder: cache, pollInterval: .milliseconds(15)) { [unowned self] url in
            self.opened.append(url)
            return self.accepts
        }
        coordinator.onRemoteChanged = { [unowned self] id, directory in self.changes.append((id, directory)) }
        return coordinator
    }

    private func open(_ coordinator: EditCoordinator, _ provider: MockProvider, _ path: String) async throws -> EditSession {
        let file = try await provider.list(RemotePath(path).parent!).first { $0.path == RemotePath(path) }!
        XCTAssertNil(coordinator.start(file, via: provider))
        await waitUntil("ouvert dans l'éditeur") { coordinator.sessions.first?.state == .editing }
        return coordinator.sessions[0]
    }

    private func save(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: false, encoding: .utf8)
    }

    private func remoteText(_ provider: MockProvider, _ path: String) async -> String? {
        await provider.contents[RemotePath(path)].map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: Ouvrir

    func testOpeningDownloadsTheFileAndHandsItToTheEditor() async throws {
        let provider = MockProvider(files: ["/site/index.html": "<h1>v1</h1>"])
        let coordinator = makeCoordinator()
        let session = try await open(coordinator, provider, "/site/index.html")

        XCTAssertEqual(opened, [session.localURL])
        XCTAssertEqual(session.localURL.lastPathComponent, "index.html")
        XCTAssertTrue(session.localURL.path.hasPrefix(cache.path), "la copie vit dans le cache de Fil")
        XCTAssertEqual(try String(contentsOf: session.localURL, encoding: .utf8), "<h1>v1</h1>")
        XCTAssertEqual(session.phrase(), "Ouvert dans ton éditeur : chaque enregistrement est envoyé au serveur.")
        let journal = await provider.journal
        XCTAssertEqual(journal, ["download /site/index.html from 0"])
    }

    func testOnlyFilesUnderTheSizeLimitAreOpened() throws {
        let coordinator = makeCoordinator()
        let provider = MockProvider()
        let folder = RemoteFile(name: "dossier", path: RemotePath("/dossier"), kind: .directory)
        XCTAssertEqual(coordinator.start(folder, via: provider), "« dossier » est un dossier : on ne modifie que des fichiers.")
        let big = RemoteFile(name: "gros.iso", path: RemotePath("/gros.iso"), kind: .file, byteCount: EditCoordinator.maximumBytes + 1)
        let reason = try XCTUnwrap(coordinator.start(big, via: provider))
        XCTAssertTrue(reason.contains("trop gros"), reason)
        XCTAssertTrue(reason.contains("Télécharge-le plutôt"), reason)
        XCTAssertTrue(coordinator.sessions.isEmpty)
    }

    func testOpeningTheSameFileTwiceReopensInsteadOfDuplicating() async throws {
        let provider = MockProvider(files: ["/a.txt": "x"])
        let coordinator = makeCoordinator()
        let first = try await open(coordinator, provider, "/a.txt")
        let file = try await provider.list(.root)[0]

        XCTAssertNil(coordinator.start(file, via: provider))
        XCTAssertEqual(coordinator.sessions.count, 1, "une seule copie : deux copies se disputeraient le fichier")
        XCTAssertEqual(opened, [first.localURL, first.localURL])
        let journal = await provider.journal
        XCTAssertEqual(journal.filter { $0.hasPrefix("download") }.count, 1)
    }

    func testNoApplicationToOpenTheFileIsSaidPlainly() async throws {
        accepts = false
        let provider = MockProvider(files: ["/a.xyz": "x"])
        let coordinator = makeCoordinator()
        let file = try await provider.list(.root)[0]

        XCTAssertNil(coordinator.start(file, via: provider))
        await waitUntil("échec d'ouverture") { if case .failed = coordinator.sessions.first?.state { true } else { false } }
        XCTAssertEqual(coordinator.sessions[0].state, .failed("Aucune application ne sait ouvrir « a.xyz ». Choisis un éditeur dans les réglages."))
        XCTAssertTrue(FileManager.default.fileExists(atPath: coordinator.sessions[0].localURL.path), "la copie est gardée")
    }

    // MARK: Enregistrer

    func testSavingSendsTheFileAtomically() async throws {
        let provider = MockProvider(files: ["/site/index.html": "<h1>v1</h1>"])
        let coordinator = makeCoordinator()
        let session = try await open(coordinator, provider, "/site/index.html")

        try save("<h1>v2</h1>", to: session.localURL)
        await waitUntil("envoyé") { coordinator.sessions.first?.syncedAt != nil }

        let remote = await remoteText(provider, "/site/index.html")
        XCTAssertEqual(remote, "<h1>v2</h1>")
        XCTAssertEqual(coordinator.sessions[0].state, .editing)
        let journal = await provider.journal
        XCTAssertEqual(Array(journal.suffix(2)), ["upload /site/index.html.filpart from 0", "move /site/index.html.filpart -> /site/index.html"])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.1, RemotePath("/site"), "l'écran qui affiche ce dossier peut se mettre à jour")
        XCTAssertTrue(coordinator.sessions[0].phrase().hasPrefix("Dernier enregistrement envoyé à"))
    }

    func testEveryNewSaveIsSent() async throws {
        let provider = MockProvider(files: ["/a.txt": "un"])
        let coordinator = makeCoordinator()
        let session = try await open(coordinator, provider, "/a.txt")

        try save("deux", to: session.localURL)
        await waitUntil("deuxième version") { await self.remoteText(provider, "/a.txt") == "deux" }
        await waitUntil("de nouveau au repos") { coordinator.sessions.first?.state == .editing }
        try save("trois!", to: session.localURL)
        await waitUntil("troisième version") { await self.remoteText(provider, "/a.txt") == "trois!" }
    }

    func testSavingWithoutChangingAnythingSendsNothing() async throws {
        let provider = MockProvider(files: ["/a.txt": "inchangé"])
        let coordinator = makeCoordinator()
        let session = try await open(coordinator, provider, "/a.txt")

        // L'éditeur a « enregistré » : même contenu, date neuve.
        try save("inchangé", to: session.localURL)
        try await Task.sleep(for: .milliseconds(200))

        let journal = await provider.journal
        XCTAssertFalse(journal.contains { $0.hasPrefix("upload") }, "rien à envoyer : \(journal)")
        XCTAssertNil(coordinator.sessions[0].syncedAt)
        XCTAssertTrue(changes.isEmpty)
    }

    func testAnEditorThatReplacesTheFileIsDetected() async throws {
        let provider = MockProvider(files: ["/a.txt": "avant"])
        let coordinator = makeCoordinator()
        let session = try await open(coordinator, provider, "/a.txt")

        // La plupart des éditeurs écrivent un fichier à côté puis le glissent à la place de l'ancien.
        let replacement = session.localURL.deletingLastPathComponent().appendingPathComponent(".a.txt.sb-tmp")
        try save("après remplacement", to: replacement)
        _ = try FileManager.default.replaceItemAt(session.localURL, withItemAt: replacement)

        await waitUntil("envoyé") { await self.remoteText(provider, "/a.txt") == "après remplacement" }
    }

    func testTheOriginalNameIsKeptEvenWhenItIsDecomposed() async throws {
        // Un serveur Linux peut garder « é » en deux caractères ; renvoyer sous la forme composée créerait un doublon.
        let decomposed = "re\u{0301}sume\u{0301}.txt"
        let provider = MockProvider(files: ["/\(decomposed)": "avant"])
        let coordinator = makeCoordinator()
        let file = try await provider.list(.root)[0]
        XCTAssertNil(coordinator.start(file, via: provider))
        await waitUntil("ouvert") { coordinator.sessions.first?.state == .editing }

        try save("après", to: coordinator.sessions[0].localURL)
        await waitUntil("envoyé") { coordinator.sessions.first?.syncedAt != nil }
        let names = await provider.contents.keys.map { Array($0.name.utf8) }
        XCTAssertEqual(names, [Array(decomposed.utf8)], "un seul fichier, sous son nom d'origine")
    }

    // MARK: Le serveur a bougé

    func testAChangeOnTheServerIsNeverOverwrittenSilently() async throws {
        let provider = MockProvider(files: ["/a.txt": "version d'origine"])
        let coordinator = makeCoordinator()
        let session = try await open(coordinator, provider, "/a.txt")

        await provider.put("/a.txt", "quelqu'un d'autre a écrit ici")
        try save("ma version", to: session.localURL)
        await waitUntil("conflit") { if case .conflict = coordinator.sessions.first?.state { true } else { false } }

        XCTAssertEqual(coordinator.sessions[0].state, .conflict("« a.txt » a changé sur le serveur depuis que tu l'as ouvert."))
        let remote = await remoteText(provider, "/a.txt")
        XCTAssertEqual(remote, "quelqu'un d'autre a écrit ici", "le serveur n'a pas été touché")
        XCTAssertEqual(try String(contentsOf: session.localURL, encoding: .utf8), "ma version", "la copie de l'utilisateur est intacte")
        XCTAssertTrue(coordinator.sessions[0].needsAttention)

        coordinator.overwrite(session.id)
        await waitUntil("écrasé après accord") { await self.remoteText(provider, "/a.txt") == "ma version" }
        await waitUntil("de nouveau au repos") { coordinator.sessions.first?.state == .editing }
    }

    func testAFileDeletedOnTheServerIsAConflictToo() async throws {
        let provider = MockProvider(files: ["/a.txt": "x", "/b.txt": "y"])
        let coordinator = makeCoordinator()
        let session = try await open(coordinator, provider, "/a.txt")

        try await provider.delete(RemoteFile(name: "a.txt", path: RemotePath("/a.txt"), kind: .file))
        try save("je tiens à ce fichier", to: session.localURL)
        await waitUntil("conflit") { if case .conflict = coordinator.sessions.first?.state { true } else { false } }
        XCTAssertEqual(coordinator.sessions[0].state, .conflict("« a.txt » n'existe plus sur le serveur."))

        coordinator.overwrite(session.id)
        await waitUntil("recréé") { await self.remoteText(provider, "/a.txt") == "je tiens à ce fichier" }
    }

    func testOurOwnUploadIsNotAConflictNextTime() async throws {
        let provider = MockProvider(files: ["/a.txt": "un"])
        let coordinator = makeCoordinator()
        let session = try await open(coordinator, provider, "/a.txt")

        try save("deux", to: session.localURL)
        await waitUntil("premier envoi") { coordinator.sessions.first?.syncedAt != nil }
        let first = coordinator.sessions[0].syncedAt
        try save("trois", to: session.localURL)
        await waitUntil("second envoi") { coordinator.sessions.first?.syncedAt != first }
        XCTAssertEqual(coordinator.sessions[0].state, .editing, "la date posée par notre propre envoi n'est pas un changement d'un tiers")
        let remote = await remoteText(provider, "/a.txt")
        XCTAssertEqual(remote, "trois")
    }

    // MARK: Pannes

    func testAFailedSendKeepsTheCopyAndIsRetriedOnlyOnRequest() async throws {
        let provider = MockProvider(files: ["/a.txt": "avant"])
        let coordinator = makeCoordinator()
        let session = try await open(coordinator, provider, "/a.txt")

        await provider.set(transferError: ProviderError.connectionLost)
        try save("pendant la panne", to: session.localURL)
        await waitUntil("échec") { if case .failed = coordinator.sessions.first?.state { true } else { false } }
        XCTAssertEqual(coordinator.sessions[0].state, .failed("La connexion au serveur s'est interrompue."))
        XCTAssertEqual(try String(contentsOf: session.localURL, encoding: .utf8), "pendant la panne")

        // Pas de boucle : l'échec n'est pas rejoué tant que le fichier ne change pas.
        let before = await provider.journal.filter { $0.hasPrefix("upload") }.count
        try await Task.sleep(for: .milliseconds(200))
        let after = await provider.journal.filter { $0.hasPrefix("upload") }.count
        XCTAssertEqual(before, after)

        await provider.set(transferError: nil)
        coordinator.retry(session.id)
        await waitUntil("envoyé après réessai") { await self.remoteText(provider, "/a.txt") == "pendant la panne" }
        await waitUntil("au repos") { coordinator.sessions.first?.state == .editing }
    }

    func testANewSaveAfterAFailureTriesAgainOnItsOwn() async throws {
        let provider = MockProvider(files: ["/a.txt": "avant"])
        let coordinator = makeCoordinator()
        let session = try await open(coordinator, provider, "/a.txt")

        await provider.set(transferError: ProviderError.connectionLost)
        try save("première tentative", to: session.localURL)
        await waitUntil("échec") { if case .failed = coordinator.sessions.first?.state { true } else { false } }

        await provider.set(transferError: nil)
        try save("seconde tentative, plus longue", to: session.localURL)
        await waitUntil("envoyé") { await self.remoteText(provider, "/a.txt") == "seconde tentative, plus longue" }
    }

    // MARK: Terminer, abandonner, quitter

    func testFinishingWhenEverythingIsSentRemovesTheLocalCopy() async throws {
        let provider = MockProvider(files: ["/a.txt": "un"])
        let coordinator = makeCoordinator()
        let session = try await open(coordinator, provider, "/a.txt")
        try save("deux", to: session.localURL)
        await waitUntil("envoyé") { coordinator.sessions.first?.syncedAt != nil }

        await coordinator.finish(session.id)
        XCTAssertTrue(coordinator.sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.localURL.deletingLastPathComponent().path))
    }

    func testFinishingRightAfterSavingSendsThatSaveFirst() async throws {
        let provider = MockProvider(files: ["/a.txt": "un"])
        let coordinator = makeCoordinator()
        let session = try await open(coordinator, provider, "/a.txt")

        try save("enregistré à l'instant", to: session.localURL)
        await coordinator.finish(session.id)

        let remote = await remoteText(provider, "/a.txt")
        XCTAssertEqual(remote, "enregistré à l'instant", "un enregistrement tout frais n'est pas perdu")
        XCTAssertTrue(coordinator.sessions.isEmpty)
    }

    func testFinishingWithAConflictKeepsTheCopy() async throws {
        let provider = MockProvider(files: ["/a.txt": "un"])
        let coordinator = makeCoordinator()
        let session = try await open(coordinator, provider, "/a.txt")
        await provider.put("/a.txt", "changé ailleurs")
        try save("mes changements", to: session.localURL)

        await coordinator.finish(session.id)
        XCTAssertEqual(coordinator.sessions.count, 1, "rien n'est supprimé tant que des changements ne sont pas partis")
        guard let kept = coordinator.sessions.first else { return }
        if case .conflict = kept.state {} else { XCTFail("\(kept.state)") }
        XCTAssertEqual(try String(contentsOf: session.localURL, encoding: .utf8), "mes changements")
    }

    func testDiscardingRemovesTheCopyAndSendsNothing() async throws {
        let provider = MockProvider(files: ["/a.txt": "un"])
        let coordinator = makeCoordinator()
        let session = try await open(coordinator, provider, "/a.txt")
        coordinator.discard(session.id)

        XCTAssertTrue(coordinator.sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.localURL.path))
        let journal = await provider.journal
        XCTAssertFalse(journal.contains { $0.hasPrefix("upload") })
    }

    func testUnsentChangesAreReportedBeforeQuitting() async throws {
        let provider = MockProvider(files: ["/a.txt": "un"])
        let coordinator = makeCoordinator()
        let session = try await open(coordinator, provider, "/a.txt")
        XCTAssertTrue(coordinator.unsentSessions.isEmpty, "rien n'a changé")

        // Enregistré il y a un instant : pas encore vu par la surveillance, mais pas encore parti.
        try save("trop récent pour être parti", to: session.localURL)
        XCTAssertEqual(coordinator.unsentSessions.map(\.id), [session.id])
        await waitUntil("envoyé") { coordinator.sessions.first?.syncedAt != nil }
        XCTAssertTrue(coordinator.unsentSessions.isEmpty)
    }

    func testEndOfSessionKeepsCopiesThatHoldUnsentChanges() async throws {
        let provider = MockProvider(files: ["/a.txt": "un", "/b.txt": "deux"])
        let coordinator = makeCoordinator()
        let sent = try await open(coordinator, provider, "/a.txt")
        let other = try await provider.list(.root).first { $0.name == "b.txt" }!
        XCTAssertNil(coordinator.start(other, via: provider))
        await waitUntil("deux ouverts") { coordinator.sessions.count == 2 && coordinator.sessions.allSatisfy { $0.state == .editing } }
        let unsent = coordinator.sessions.first { $0.id != sent.id }!
        await provider.put("/b.txt", "changé ailleurs")
        try save("mes changements", to: unsent.localURL)
        await waitUntil("conflit") { coordinator.sessions.contains { if case .conflict = $0.state { true } else { false } } }

        coordinator.removeSyncedCopies()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sent.localURL.path), "tout est parti : la copie s'en va")
        XCTAssertEqual(try String(contentsOf: unsent.localURL, encoding: .utf8), "mes changements", "des changements en attente ne sont jamais supprimés")
    }

    func testStaleCopiesAreRemovedAtLaunchAndRecentOnesAreKept() throws {
        let coordinator = makeCoordinator()
        let old = cache.appendingPathComponent("vieille", isDirectory: true)
        let recent = cache.appendingPathComponent("recente", isDirectory: true)
        for folder in [old, recent] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)], ofItemAtPath: old.path)

        coordinator.purgeStaleFolders()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    // MARK: Interface

    func testBrowserModelEditsOnlyASingleFile() async throws {
        let provider = MockProvider(files: ["/a.txt": "un", "/b.txt": "deux", "/dossier/c.txt": "trois"])
        let coordinator = makeCoordinator()
        let browser = BrowserModel(connection: provider.connection, provider: provider, home: .root, transfers: TransferQueue(), edits: coordinator) { self.cache }
        await waitUntil("listing") { browser.status == .ready }

        XCTAssertFalse(browser.canEditSelection)
        browser.selection = ["/a.txt", "/b.txt"]
        XCTAssertFalse(browser.canEditSelection)
        browser.selection = ["/dossier"]
        XCTAssertFalse(browser.canEditSelection, "un dossier ne se modifie pas")
        browser.selection = ["/a.txt"]
        XCTAssertTrue(browser.canEditSelection)

        browser.editSelection()
        await waitUntil("ouvert") { coordinator.sessions.first?.state == .editing }
        XCTAssertNil(browser.notice)
    }

    func testTooBigAFileShowsAReasonInTheBrowser() async throws {
        let provider = MockProvider(files: ["/a.txt": "un"])
        let coordinator = makeCoordinator()
        let browser = BrowserModel(connection: provider.connection, provider: provider, home: .root, transfers: TransferQueue(), edits: coordinator) { self.cache }
        await waitUntil("listing") { browser.status == .ready }
        browser.edit(RemoteFile(name: "gros.iso", path: RemotePath("/gros.iso"), kind: .file, byteCount: EditCoordinator.maximumBytes * 2))
        XCTAssertEqual(browser.notice?.contains("trop gros"), true)
    }
}

final class EditSessionPhraseTests: XCTestCase {
    private func session(_ state: EditSession.State) -> EditSession {
        EditSession(connectionID: UUID(), connectionName: "S", remotePath: RemotePath("/site/a.txt"), localURL: URL(fileURLWithPath: "/tmp/a.txt"), state: state)
    }

    func testEveryStateSaysWhatItIsWaitingFor() {
        var downloading = session(.downloading)
        XCTAssertEqual(downloading.phrase(), "Téléchargement de « a.txt »…")
        downloading.totalBytes = 4_000_000
        downloading.downloadedBytes = 1_000_000
        XCTAssertEqual(downloading.phrase().replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " "), "Téléchargement de « a.txt » · 1 Mo sur 4 Mo")
        XCTAssertEqual(session(.uploading).phrase(), "Envoi des modifications…")
        XCTAssertEqual(session(.conflict("Le serveur a changé.")).phrase(), "Le serveur a changé. Écraser la version du serveur, ou abandonner tes changements.")
        XCTAssertEqual(session(.failed("Pas de réseau.")).phrase(), "Pas de réseau. Ta copie est conservée.")
    }

    func testOnlyConflictsAndFailuresNeedAttention() {
        XCTAssertFalse(session(.downloading).needsAttention)
        XCTAssertFalse(session(.editing).needsAttention)
        XCTAssertFalse(session(.uploading).needsAttention)
        XCTAssertTrue(session(.conflict("x")).needsAttention)
        XCTAssertTrue(session(.failed("x")).needsAttention)
    }
}
