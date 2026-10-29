import XCTest
@testable import Fil

/// « Relancer » un transfert qui n'avance plus, renommer pendant un transfert, fichier réécrit à la même taille.
@MainActor
final class TransferRestartTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = try makeTemporaryFolder()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func isFailed(_ queue: TransferQueue) -> Bool {
        if case .failed = queue.items.first?.state { return true }
        return false
    }

    /// Une heure plus tard : tout transfert qui n'a pas bougé est alors dit bloqué.
    private var later: Date { Date().addingTimeInterval(TransferItem.stallDelay + 5) }

    // MARK: Relancer

    func testRestartCutsAStalledDownloadAndResumesFromItsPartial() async throws {
        let text = String(repeating: "0123456789", count: 10)
        let provider = MockProvider(files: ["/big.bin": text])
        await provider.set(chunkDelay: .milliseconds(2))
        let queue = TransferQueue()
        let file = try await provider.list(.root)[0]

        queue.download([file], via: provider, into: folder)
        await waitUntil("début du transfert") { queue.items.first?.transferredBytes ?? 0 >= 20 }
        // Le serveur se fige : plus un octet n'arrive.
        await provider.set(chunkDelay: .seconds(60))
        await waitUntil("figé") { LocalFile.size(of: self.folder.appendingPathComponent("big.bin.filpart")) != nil }
        let id = queue.items[0].id

        XCTAssertFalse(queue.canRestart(id, now: .now), "un transfert qui vient d'avancer n'est pas bloqué")
        XCTAssertTrue(queue.canRestart(id, now: later))
        let stuckAt = LocalFile.size(of: folder.appendingPathComponent("big.bin.filpart")) ?? 0

        await provider.set(chunkDelay: .zero)
        queue.restart(id, now: later)
        await waitUntil("repris et terminé") { queue.items.first?.state == .done }

        let journal = await provider.journal
        XCTAssertEqual(journal.count, 2, "\(journal)")
        XCTAssertTrue(journal[1].hasPrefix("download /big.bin from "), "\(journal)")
        XCTAssertNotEqual(journal[1], "download /big.bin from 0", "il reprend depuis le partiel, il ne recommence pas")
        XCTAssertGreaterThanOrEqual(stuckAt, 20)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("big.bin"), encoding: .utf8), text)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["big.bin"], "aucun partiel oublié")
        XCTAssertEqual(queue.items.count, 1, "c'est le même transfert, pas un second")
    }

    func testRestartKeepsTheRemotePartialOfAnUpload() async throws {
        let text = String(repeating: "abcdefghij", count: 10)
        let provider = MockProvider(files: ["/site/index.html": "ancienne version"])
        await provider.set(chunkDelay: .milliseconds(2))
        let queue = TransferQueue()
        let source = folder.appendingPathComponent("index.html")
        try text.write(to: source, atomically: true, encoding: .utf8)

        queue.upload([source], into: RemotePath("/site"), via: provider)
        await waitUntil("début de l'envoi") { (await provider.contents[RemotePath("/site/index.html.filpart")]?.count ?? 0) >= 20 }
        await provider.set(chunkDelay: .seconds(60))
        try await Task.sleep(for: .milliseconds(50))
        await provider.set(chunkDelay: .zero)
        queue.restart(queue.items[0].id, now: later)
        await waitUntil("terminé") { queue.items.first?.state == .done }

        let journal = await provider.journal
        XCTAssertEqual(journal.filter { $0.hasPrefix("upload") }.count, 2, "\(journal)")
        XCTAssertNotEqual(journal.filter { $0.hasPrefix("upload") }.last, "upload /site/index.html.filpart from 0", "\(journal)")
        let final = await provider.contents[RemotePath("/site/index.html")]
        XCTAssertEqual(final, Data(text.utf8))
    }

    func testRestartDoesNothingForATransferThatMoves() async throws {
        let provider = MockProvider(files: ["/big.bin": String(repeating: "x", count: 50)])
        await provider.set(chunkDelay: .milliseconds(5))
        let queue = TransferQueue()
        let file = try await provider.list(.root)[0]
        queue.download([file], via: provider, into: folder)
        await waitUntil("en cours") { queue.items.first?.state == .running }

        queue.restart(queue.items[0].id)
        await waitUntil("terminé") { queue.items.first?.state == .done }
        let journal = await provider.journal
        XCTAssertEqual(journal, ["download /big.bin from 0"], "aucune coupure inutile")
    }

    func testCancellingDuringARestartAbandonsTheTransfer() async throws {
        let provider = MockProvider(files: ["/big.bin": String(repeating: "x", count: 50)])
        await provider.set(chunkDelay: .seconds(60))
        let queue = TransferQueue()
        let file = try await provider.list(.root)[0]
        queue.download([file], via: provider, into: folder)
        await waitUntil("en cours") { queue.items.first?.state == .running }
        let id = queue.items[0].id

        queue.restart(id, now: later)
        queue.cancel(id)
        await waitUntil("annulé") { queue.items.first?.state == .cancelled }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(queue.items[0].state, .cancelled, "personne ne relance ce que l'utilisateur a annulé")
        XCTAssertFalse(queue.hasActive)
    }

    func testAnotherApplicationsPromiseIsNeverRestarted() async throws {
        let provider = MockProvider(files: ["/big.bin": String(repeating: "x", count: 50)])
        await provider.set(chunkDelay: .seconds(60))
        let queue = TransferQueue()
        let file = try await provider.list(.root)[0]
        queue.download(file, via: provider, into: folder) { _ in }
        await waitUntil("en cours") { queue.items.first?.state == .running }
        XCTAssertFalse(queue.canRestart(queue.items[0].id, now: later), "l'application qui attend le fichier n'attendrait plus la même tâche")
        queue.cancelAll()
    }

    // MARK: Renommer pendant un transfert

    func testRenamingAFileBeingTransferredIsRefused() async throws {
        let provider = MockProvider(files: ["/docs/gros.bin": String(repeating: "x", count: 50), "/docs/autre.txt": "a", "/ailleurs/x.txt": "a"])
        await provider.set(chunkDelay: .seconds(60))
        let queue = TransferQueue()
        let browser = BrowserModel(connection: provider.connection, provider: provider, home: RemotePath("/docs"), transfers: queue) { self.folder }
        let big = try await provider.list(RemotePath("/docs")).first { $0.name == "gros.bin" }!
        let other = try await provider.list(RemotePath("/docs")).first { $0.name == "autre.txt" }!
        let docs = RemoteFile(name: "docs", path: RemotePath("/docs"), kind: .directory)

        queue.download([big], via: provider, into: folder)
        await waitUntil("en cours") { queue.items.first?.state == .running }

        XCTAssertEqual(browser.renameProblem(big, to: "énorme.bin"), "« gros.bin » est en cours de transfert. Attends la fin, ou annule-le, avant de renommer.")
        XCTAssertEqual(browser.renameProblem(docs, to: "papiers")?.hasPrefix("« gros.bin » est en cours"), true, "renommer le dossier qui le contient casse aussi le chemin")
        XCTAssertNil(browser.renameProblem(other, to: "autre-nom.txt"), "un voisin reste libre")

        queue.cancelAll()
        await waitUntil("annulé") { queue.items.first?.state == .cancelled }
        XCTAssertNil(browser.renameProblem(big, to: "énorme.bin"), "le transfert fini, le nom est libre")
    }

    func testRenamingAFolderOnAnotherConnectionIsNotBlocked() async throws {
        let busy = MockProvider(connection: RemoteConnection(name: "A", host: "a.test"), files: ["/docs/gros.bin": String(repeating: "x", count: 50)])
        let idle = MockProvider(connection: RemoteConnection(name: "B", host: "b.test"), files: ["/docs/gros.bin": "x"])
        await busy.set(chunkDelay: .seconds(60))
        let queue = TransferQueue()
        let browser = BrowserModel(connection: idle.connection, provider: idle, home: RemotePath("/docs"), transfers: queue) { self.folder }
        let file = try await busy.list(RemotePath("/docs"))[0]
        queue.download([file], via: busy, into: folder)
        await waitUntil("en cours") { queue.items.first?.state == .running }

        let same = try await idle.list(RemotePath("/docs"))[0]
        XCTAssertNil(browser.renameProblem(same, to: "autre.bin"))
        queue.cancelAll()
    }

    // MARK: Fichier réécrit à la même taille

    func testDownloadRestartsWhenTheRemoteFileWasRewrittenAtTheSameSize() async throws {
        let provider = MockProvider(files: ["/journal.log": String(repeating: "a", count: 100)])
        await provider.set(interruptAfter: 30)
        let queue = TransferQueue()
        let file = try await provider.list(.root)[0]

        queue.download([file], via: provider, into: folder)
        await waitUntil("échec") { self.isFailed(queue) }
        // Réécrit, même taille : la taille seule ne trahit rien, la date si.
        let fresh = String(repeating: "b", count: 100)
        await provider.put("/journal.log", fresh)
        queue.retry(queue.items[0].id)
        await waitUntil("terminé") { queue.items.first?.state == .done }

        let journal = await provider.journal
        XCTAssertEqual(journal, ["download /journal.log from 0", "download /journal.log from 0"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("journal.log"), encoding: .utf8), fresh, "aucun octet de l'ancienne version ne survit")
    }

    func testAnUnchangedFileStillResumesWhenItsDateIsKnown() async throws {
        let text = String(repeating: "0123456789", count: 10)
        let provider = MockProvider(files: ["/big.bin": text])
        await provider.set(interruptAfter: 30)
        let queue = TransferQueue()
        let file = try await provider.list(.root)[0]
        XCTAssertNotNil(file.modifiedAt)

        queue.download([file], via: provider, into: folder)
        await waitUntil("échec") { self.isFailed(queue) }
        queue.retry(queue.items[0].id)
        await waitUntil("terminé") { queue.items.first?.state == .done }
        let journal = await provider.journal
        XCTAssertEqual(journal, ["download /big.bin from 0", "download /big.bin from 30"])
    }
}
