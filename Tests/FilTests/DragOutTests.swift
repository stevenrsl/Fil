import XCTest
@testable import Fil

@MainActor
final class DragOutTests: XCTestCase {
    private final class Outcomes {
        var values: [Result<URL, Error>] = []
    }

    func testPromisedDownloadDeliversTheFinalFile() async throws {
        let provider = MockProvider(files: ["/www/index.html": "<p>", "/www/css/site.css": "body{}"])
        let queue = TransferQueue()
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let outcomes = Outcomes()

        let file = RemoteFile(name: "index.html", path: RemotePath("/www/index.html"), kind: .file, byteCount: 3)
        queue.download(file, via: provider, into: folder) { outcomes.values.append($0) }
        let directory = RemoteFile(name: "www", path: RemotePath("/www"), kind: .directory)
        let folderID = queue.download(directory, via: provider, into: folder) { outcomes.values.append($0) }
        await waitUntil("livrés") { outcomes.values.count == 2 }

        let urls = try outcomes.values.map { try $0.get() }
        let delivered = try XCTUnwrap(urls.first { $0.lastPathComponent == "index.html" })
        XCTAssertEqual(try String(contentsOf: delivered, encoding: .utf8), "<p>")
        let tree = try XCTUnwrap(urls.first { $0.lastPathComponent == "www" })
        XCTAssertEqual(try String(contentsOf: tree.appendingPathComponent("css/site.css"), encoding: .utf8), "body{}")
        // Personne n'attend plus ce fichier : il ne se relance pas.
        XCTAssertFalse(queue.canRetry(folderID))
    }

    func testPromiseReportsFailureOnceAndCannotBeRetried() async throws {
        let provider = MockProvider(files: ["/a.bin": "abc"])
        await provider.set(transferError: ProviderError.accessDenied("a.bin"))
        let queue = TransferQueue()
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let outcomes = Outcomes()
        let id = queue.download(RemoteFile(name: "a.bin", path: RemotePath("/a.bin"), kind: .file, byteCount: 3), via: provider, into: folder) { outcomes.values.append($0) }
        await waitUntil("échec") { !outcomes.values.isEmpty }
        XCTAssertThrowsError(try outcomes.values[0].get())
        XCTAssertFalse(queue.canRetry(id))
        queue.retry(id)
        XCTAssertFalse(queue.items[0].isActive)
        XCTAssertEqual(outcomes.values.count, 1)
    }

    func testCancellingAWaitingPromiseAnswersTheReceiver() async throws {
        let provider = MockProvider(files: ["/a": "1", "/b": "2"])
        await provider.set(chunkDelay: .milliseconds(200))
        await provider.set(chunkSize: 1)
        let queue = TransferQueue(maxConcurrent: 1)
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let outcomes = Outcomes()
        queue.download([RemoteFile(name: "a", path: RemotePath("/a"), kind: .file, byteCount: 1)], via: provider, into: folder)
        let waiting = queue.download(RemoteFile(name: "b", path: RemotePath("/b"), kind: .file, byteCount: 1), via: provider, into: folder) { outcomes.values.append($0) }
        queue.cancel(waiting)
        XCTAssertEqual(outcomes.values.count, 1)
        XCTAssertTrue((try? outcomes.values[0].get()) == nil)
        queue.cancelAll()
    }

    func testDragCacheRecognisesItsOwnFilesAndPurgesOldOnes() throws {
        let root = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let fresh = try DragCache.makeFolder(in: root)
        let old = try DragCache.makeFolder(in: root)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * DragCache.staleAfter)], ofItemAtPath: old.path)

        XCTAssertTrue(DragCache.contains(fresh.appendingPathComponent("a.txt"), root: root))
        XCTAssertFalse(DragCache.contains(URL(fileURLWithPath: "/Users/moi/a.txt"), root: root))
        XCTAssertFalse(DragCache.contains(root, root: root))

        DragCache.purgeStale(in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testLinksOfUnknownTargetCannotBeDragged() async {
        let provider = MockProvider(files: ["/a.txt": "x"])
        let browser = BrowserModel(connection: provider.connection, provider: provider, home: .root, transfers: TransferQueue()) { FileManager.default.temporaryDirectory }
        XCTAssertNil(browser.dragItem(for: RemoteFile(name: "lien", path: RemotePath("/lien"), kind: .link)))
        let item = browser.dragItem(for: RemoteFile(name: "a.txt", path: RemotePath("/a.txt"), kind: .file, byteCount: 1))
        XCTAssertEqual(item?.suggestedName, "a.txt")
        XCTAssertEqual(item?.registeredTypeIdentifiers, ["public.plain-text"])
    }

    /// Ce que fait l'application qui reçoit le dépôt : demander le fichier, une fois arrivé.
    func testItemProviderHandsOverTheDownloadedFile() async throws {
        let provider = MockProvider(files: ["/notes.txt": "bonjour"])
        let queue = TransferQueue()
        let browser = BrowserModel(connection: provider.connection, provider: provider, home: .root, transfers: queue) { FileManager.default.temporaryDirectory }
        let item = try XCTUnwrap(browser.dragItem(for: RemoteFile(name: "notes.txt", path: RemotePath("/notes.txt"), kind: .file, byteCount: 7)))
        let text = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            _ = item.loadFileRepresentation(forTypeIdentifier: "public.plain-text") { url, error in
                if let url, let text = try? String(contentsOf: url, encoding: .utf8) {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
        XCTAssertEqual(text, "bonjour")
        XCTAssertEqual(queue.items.first?.state, .done)
        if let delivered = queue.items.first?.localURL { try? FileManager.default.removeItem(at: delivered.deletingLastPathComponent()) }
    }
}
