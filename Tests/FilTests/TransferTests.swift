import XCTest
@testable import Fil

final class LocalNamingTests: XCTestCase {
    func testAvailableNameAddsANumberBeforeTheExtension() {
        let taken: Set<String> = ["/d/rapport.pdf", "/d/rapport (2).pdf"]
        let url = LocalNaming.available(URL(fileURLWithPath: "/d/rapport.pdf")) { taken.contains($0.path) }
        XCTAssertEqual(url.lastPathComponent, "rapport (3).pdf")
        let folder = LocalNaming.available(URL(fileURLWithPath: "/d/Photos", isDirectory: true)) { $0.lastPathComponent == "Photos" }
        XCTAssertEqual(folder.lastPathComponent, "Photos (2)")
    }

    func testRemoteNamesAreComposed() {
        // Swift compare les chaînes à équivalence canonique près : on vérifie les octets.
        let decomposed = URL(fileURLWithPath: "/tmp/e\u{0301}te\u{0301}.txt")
        XCTAssertEqual(Array(LocalNaming.remoteName(for: decomposed).utf8), Array("\u{00E9}t\u{00E9}.txt".utf8))
    }

    func testReservationsNeverCollide() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try LocalNaming.reserveFile(named: "a.txt", in: folder)
        let second = try LocalNaming.reserveFile(named: "a.txt", in: folder)
        XCTAssertEqual(first.final.lastPathComponent, "a.txt")
        XCTAssertEqual(second.final.lastPathComponent, "a (2).txt")
        XCTAssertEqual(first.partial.lastPathComponent, "a.txt.filpart")
        let completed = try LocalNaming.complete(first.partial, as: first.final)
        XCTAssertEqual(completed.lastPathComponent, "a.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.partial.path))
    }
}

final class TransferItemTests: XCTestCase {
    func testPhrases() {
        let now = Date()
        var item = TransferItem(direction: .download, name: "a.bin", isFolder: false, connectionName: "S", remotePath: RemotePath("/a.bin"), localURL: URL(fileURLWithPath: "/tmp"), totalBytes: 4_000_000)
        XCTAssertEqual(item.phrase(now: now), "En attente d'une place libre")
        item.state = .running
        item.startedAt = now.addingTimeInterval(-2)
        item.transferredBytes = 2_000_000
        let running = item.phrase(now: now).replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        XCTAssertEqual(running, "2 Mo sur 4 Mo · 1 Mo/s · encore 2 s")
        XCTAssertEqual(item.fraction, 0.5)
        item.state = .failed("Le serveur ne répond pas.")
        XCTAssertEqual(item.phrase(now: now), "Le serveur ne répond pas.")
        XCTAssertFalse(item.isActive)
    }

    func testFolderPhraseCountsFiles() {
        var item = TransferItem(direction: .upload, name: "Photos", isFolder: true, connectionName: "S", remotePath: RemotePath("/Photos"), localURL: URL(fileURLWithPath: "/tmp/Photos"))
        item.state = .preparing
        XCTAssertEqual(item.phrase(now: .now), "Inventaire du dossier…")
        item.fileCount = 12
        item.completedFiles = 2
        item.totalBytes = 10
        item.state = .running
        XCTAssertTrue(item.phrase(now: .now).hasPrefix("3 sur 12 fichiers"))
    }
}

@MainActor
final class TransferQueueTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = try makeTemporaryFolder()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testDownloadWritesFileAndNeverOverwrites() async throws {
        let provider = MockProvider(files: ["/docs/note.txt": "bonjour"])
        try "déjà là".write(to: folder.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let queue = TransferQueue()
        let file = try await provider.list(RemotePath("/docs"))[0]

        queue.download([file], via: provider, into: folder)
        await waitUntil("téléchargement terminé") { queue.items.first?.state == .done }

        let item = try XCTUnwrap(queue.items.first)
        XCTAssertEqual(item.localURL.lastPathComponent, "note (2).txt")
        XCTAssertEqual(try String(contentsOf: item.localURL, encoding: .utf8), "bonjour")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("note.txt"), encoding: .utf8), "déjà là")
        XCTAssertEqual(item.transferredBytes, 7)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".filpart") }
        XCTAssertEqual(leftovers, [])
    }

    func testFolderDownloadRebuildsTheTree() async throws {
        let provider = MockProvider(files: ["/site/index.html": "<h1>", "/site/css/style.css": "body{}", "/site/css/vendor/reset.css": "*{}"])
        let queue = TransferQueue()
        let site = try await provider.list(.root).first { $0.name == "site" }!

        queue.download([site], via: provider, into: folder)
        await waitUntil("dossier téléchargé") { queue.items.first?.state == .done }

        let root = folder.appendingPathComponent("site")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("css/vendor/reset.css"), encoding: .utf8), "*{}")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("index.html"), encoding: .utf8), "<h1>")
        XCTAssertEqual(queue.items.first?.fileCount, 3)
        XCTAssertEqual(queue.items.first?.completedFiles, 3)
    }

    func testFolderUploadCreatesDirectoriesAndSkipsDSStore() async throws {
        let source = folder.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("2026/été"), withIntermediateDirectories: true)
        try "a".write(to: source.appendingPathComponent("2026/été/plage.jpg"), atomically: true, encoding: .utf8)
        try "b".write(to: source.appendingPathComponent("couverture.jpg"), atomically: true, encoding: .utf8)
        try "x".write(to: source.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        let provider = MockProvider()
        let queue = TransferQueue()
        var finished = false

        queue.upload([source], into: .root, via: provider) { finished = true }
        await waitUntil("envoi terminé") { queue.items.first?.state == .done }

        XCTAssertTrue(finished)
        let uploaded = await provider.contents
        XCTAssertEqual(Set(uploaded.keys.map(\.value)), ["/Photos/2026/été/plage.jpg", "/Photos/couverture.jpg"])
        XCTAssertTrue(uploaded.keys.allSatisfy { Array($0.value.utf8) == Array($0.value.precomposedStringWithCanonicalMapping.utf8) })
    }

    func testFailureIsReadableAndRetryable() async throws {
        let provider = MockProvider(files: ["/a.txt": "abc"])
        await provider.set(transferError: ProviderError.connectionLost)
        let queue = TransferQueue()
        let file = try await provider.list(.root)[0]

        queue.download([file], via: provider, into: folder)
        await waitUntil("échec") { if case .failed = queue.items.first?.state { true } else { false } }
        XCTAssertEqual(queue.items.first?.state, .failed("La connexion au serveur s'est interrompue."))
        XCTAssertTrue(queue.canRetry(queue.items[0].id))
        // Une coupure garde le partiel : « Réessayer » pourra reprendre.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["a.txt.filpart"])

        await provider.set(transferError: nil)
        queue.retry(queue.items[0].id)
        await waitUntil("nouvel essai réussi") { queue.items.first?.state == .done }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["a.txt"])
    }

    func testCancelStopsAndCleansUp() async throws {
        let provider = MockProvider(files: ["/lent.bin": String(repeating: "x", count: 200)])
        await provider.set(chunkDelay: .milliseconds(5))
        let queue = TransferQueue()
        let file = try await provider.list(.root)[0]

        queue.download([file], via: provider, into: folder)
        await waitUntil("transfert lancé") { (queue.items.first?.transferredBytes ?? 0) > 0 }
        queue.cancel(queue.items[0].id)
        await waitUntil("annulé") { queue.items.first?.state == .cancelled }
        // Le nettoyage part en arrière-plan : l'annulation, elle, est immédiate.
        await waitUntil("partiel effacé") { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? ["?"]).isEmpty }
    }

    func testWaitingTransferCanBeCancelledThenRetried() async throws {
        let provider = MockProvider(files: ["/a.txt": String(repeating: "a", count: 50), "/b.txt": "b"])
        await provider.set(chunkDelay: .milliseconds(2))
        let queue = TransferQueue(maxConcurrent: 1)
        let listing = try await provider.list(.root).sorted { $0.name < $1.name }

        queue.download(listing, via: provider, into: folder)
        let waiting = queue.items[1]
        XCTAssertEqual(waiting.state, .waiting)
        queue.cancel(waiting.id)
        XCTAssertEqual(queue.items[1].state, .cancelled)
        XCTAssertTrue(queue.canRetry(waiting.id))
        queue.retry(waiting.id)
        await waitUntil("les deux terminés") { queue.items.allSatisfy { $0.state == .done } }
    }

    func testConcurrencyIsCapped() async throws {
        let files = Dictionary(uniqueKeysWithValues: (1...5).map { ("/f\($0).txt", "abcdef") })
        let provider = MockProvider(files: files)
        await provider.set(chunkDelay: .milliseconds(3))
        let queue = TransferQueue(maxConcurrent: 2)
        let listing = try await provider.list(.root)

        queue.download(listing, via: provider, into: folder)
        XCTAssertEqual(queue.items.filter { $0.state == .waiting }.count, 3)
        await waitUntil("tout est terminé") { queue.items.allSatisfy { $0.state == .done } }
        let peak = await provider.maxRunning
        XCTAssertLessThanOrEqual(peak, 2)
        XCTAssertEqual(queue.summary(now: .now), "Tout est terminé")
        queue.clearFinished()
        XCTAssertTrue(queue.items.isEmpty)
    }
}

final class DeleteTreeTests: XCTestCase {
    actor Journal {
        var entries: [String] = []
        func add(_ entry: String) { entries.append(entry) }
    }

    func testChildrenGoFirstAndLinksAreNeverFollowed() async throws {
        let journal = Journal()
        let root = RemoteFile(name: "vieux", path: RemotePath("/vieux"), kind: .directory)
        let children: [RemotePath: [RemoteFile]] = [
            RemotePath("/vieux"): [
                RemoteFile(name: "a.txt", path: RemotePath("/vieux/a.txt"), kind: .file),
                RemoteFile(name: "lien", path: RemotePath("/vieux/lien"), kind: .directory, isSymbolicLink: true),
                RemoteFile(name: "sous", path: RemotePath("/vieux/sous"), kind: .directory)
            ],
            RemotePath("/vieux/sous"): []
        ]
        try await deleteTree(
            root,
            list: { path in
                await journal.add("list \(path)")
                return children[path] ?? []
            },
            removeFile: { await journal.add("rm \($0)") },
            removeDirectory: { await journal.add("rmdir \($0)") }
        )
        let entries = await journal.entries
        XCTAssertEqual(entries, ["list /vieux", "rm /vieux/a.txt", "rm /vieux/lien", "list /vieux/sous", "rmdir /vieux/sous", "rmdir /vieux"])
    }
}
