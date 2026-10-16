import XCTest
@testable import Fil

final class StallTests: XCTestCase {
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    func testRunningTransferWithoutProgressIsSaidStalled() {
        let now = Date()
        var item = TransferItem(direction: .upload, name: "a.zip", isFolder: false, connectionName: "S", remotePath: RemotePath("/a.zip"), localURL: URL(fileURLWithPath: "/tmp/a.zip"), totalBytes: 4_000_000)
        item.state = .running
        item.startedAt = now.addingTimeInterval(-60)
        item.transferredBytes = 1_000_000
        item.lastProgressAt = now.addingTimeInterval(-10)
        XCTAssertNil(item.stalledFor(now: now))
        XCTAssertTrue(plain(item.phrase(now: now)).contains("encore"))

        item.lastProgressAt = now.addingTimeInterval(-45)
        XCTAssertEqual(item.stalledFor(now: now) ?? 0, 45, accuracy: 0.01)
        XCTAssertEqual(plain(item.phrase(now: now)), "1 Mo sur 4 Mo · rien n'avance depuis 45 s, le serveur ou le réseau peine peut-être")

        item.state = .failed("Coupé.")
        XCTAssertNil(item.stalledFor(now: now))
    }

    func testWaitingIsNeverStalled() {
        var item = TransferItem(direction: .download, name: "a", isFolder: false, connectionName: "S", remotePath: RemotePath("/a"), localURL: URL(fileURLWithPath: "/tmp"))
        item.startedAt = .distantPast
        XCTAssertNil(item.stalledFor(now: .now))
    }
}

final class TransferBatchOutcomeTests: XCTestCase {
    private func item(_ name: String, _ state: TransferItem.State, bytes: Int64? = 1_000_000) -> TransferItem {
        var item = TransferItem(direction: .upload, name: name, isFolder: false, connectionName: "S", remotePath: RemotePath("/www/\(name)"), localURL: URL(fileURLWithPath: "/tmp/\(name)"), totalBytes: bytes)
        item.state = state
        return item
    }

    func testNothingToSayWhenEverythingWasCancelled() {
        XCTAssertNil(TransferBatchOutcome.of([]))
        XCTAssertNil(TransferBatchOutcome.of([item("a", .cancelled)]))
    }

    func testSingleSuccessNamesTheFile() {
        let outcome = TransferBatchOutcome.of([item("index.html", .done)])
        XCTAssertEqual(outcome?.title, "« index.html » envoyé")
        XCTAssertEqual(outcome?.body.hasPrefix("Envoyé dans « www »"), true)
        XCTAssertEqual(outcome?.hasFailures, false)
    }

    func testSeveralSuccessesAddTheirSizes() {
        let outcome = TransferBatchOutcome.of([item("a", .done), item("b", .done), item("c", .cancelled)])
        XCTAssertEqual(outcome?.title, "Transferts terminés")
        XCTAssertEqual(outcome?.body.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " "), "2 transferts réussis · 2 Mo")
    }

    func testOneFailureGivesItsReason() {
        let outcome = TransferBatchOutcome.of([item("a", .done), item("b", .failed("Le serveur ne répond pas."))])
        XCTAssertEqual(outcome?.title, "Un transfert a échoué")
        XCTAssertEqual(outcome?.body, "« b » : Le serveur ne répond pas. L'autre est arrivé.")
        XCTAssertEqual(outcome?.hasFailures, true)
    }

    func testSeveralFailuresPointToTheTray() {
        let outcome = TransferBatchOutcome.of([item("a", .failed("x")), item("b", .failed("y")), item("c", .done), item("d", .done)])
        XCTAssertEqual(outcome?.title, "2 transferts ont échoué")
        XCTAssertEqual(outcome?.body, "2 autres sont arrivés. Le plateau des transferts dit pourquoi.")
    }
}

@MainActor
final class TransferActivityTests: XCTestCase {
    final class Recorder: TransferActivity {
        var events: [String] = []
        var outcomes: [TransferBatchOutcome?] = []
        func began() { events.append("began") }
        func ended(_ outcome: TransferBatchOutcome?) {
            events.append("ended")
            outcomes.append(outcome)
        }
    }

    private var folder: URL!

    override func setUp() async throws {
        folder = try makeTemporaryFolder()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testOneBeganAndOneEndedForAWholeBatch() async throws {
        let files = Dictionary(uniqueKeysWithValues: (1...4).map { ("/f\($0).txt", "abc") })
        let provider = MockProvider(files: files)
        await provider.set(chunkDelay: .milliseconds(2))
        let queue = TransferQueue(maxConcurrent: 1)
        let recorder = Recorder()
        queue.activity = recorder

        queue.download(try await provider.list(.root), via: provider, into: folder)
        await waitUntil("tout est terminé") { recorder.events.last == "ended" }

        XCTAssertEqual(recorder.events, ["began", "ended"])
        XCTAssertEqual(recorder.outcomes.first??.title, "Transferts terminés")
        XCTAssertEqual(recorder.outcomes.first??.body.hasPrefix("4 transferts réussis"), true)
    }

    func testRetryStartsANewBatchAboutItselfOnly() async throws {
        let provider = MockProvider(files: ["/a.txt": "abc"])
        await provider.set(transferError: ProviderError.connectionLost)
        let queue = TransferQueue()
        let recorder = Recorder()
        queue.activity = recorder

        queue.download(try await provider.list(.root), via: provider, into: folder)
        await waitUntil("échec") { recorder.events.count == 2 }
        XCTAssertEqual(recorder.outcomes.last??.title, "Un transfert a échoué")

        await provider.set(transferError: nil)
        queue.retry(queue.items[0].id)
        await waitUntil("nouvel essai") { recorder.events.count == 4 }
        XCTAssertEqual(recorder.events, ["began", "ended", "began", "ended"])
        XCTAssertEqual(recorder.outcomes.last??.title, "« a.txt » téléchargé")
    }

    func testCancellingWhatWaitedSaysNothing() async throws {
        let provider = MockProvider(files: ["/lent.bin": String(repeating: "x", count: 400)])
        await provider.set(chunkDelay: .milliseconds(5))
        let queue = TransferQueue()
        let recorder = Recorder()
        queue.activity = recorder

        queue.download(try await provider.list(.root), via: provider, into: folder)
        queue.cancelAll()
        await waitUntil("annulé") { recorder.events.last == "ended" }
        XCTAssertEqual(recorder.events, ["began", "ended"])
        XCTAssertEqual(recorder.outcomes, [nil])
    }

    func testProgressKeepsTheTransferAlive() async throws {
        let provider = MockProvider(files: ["/lent.bin": String(repeating: "x", count: 200)])
        await provider.set(chunkDelay: .milliseconds(5))
        let queue = TransferQueue()

        queue.download(try await provider.list(.root), via: provider, into: folder)
        await waitUntil("octets reçus") { (queue.items.first?.transferredBytes ?? 0) > 0 }
        let item = try XCTUnwrap(queue.items.first)
        let last = try XCTUnwrap(item.lastProgressAt)
        XCTAssertGreaterThanOrEqual(last, try XCTUnwrap(item.startedAt))
        XCTAssertNil(item.stalledFor(now: .now))
        XCTAssertNotNil(item.stalledFor(now: last.addingTimeInterval(TransferItem.stallDelay + 1)))
        queue.cancelAll()
        await waitUntil("annulé") { queue.items.first?.state == .cancelled }
    }
}
