import XCTest
@testable import Fil

final class ProtonDriveTests: XCTestCase {
    func testCommandErrorIsNotAMissingFolder() {
        let output = ProcessRunner.CapturedOutput(status: 1, standardOutput: "Usage: auth login", errorOutput: "Command not found: --json filesystem")
        guard case .server = ProtonDriveProvider.error(from: output, subject: "/my-files") else {
            return XCTFail("Une commande invalide n'est pas un dossier absent")
        }
    }

    func testListingUsesCLIArrayAndPlaintextSize() {
        let json = """
        [
          {"name":{"ok":true,"value":"été.txt"},"type":"file","totalStorageSize":999,"activeRevision":{"claimedSize":12}},
          {"name":{"ok":true,"value":"Documents"},"type":"folder"}
        ]
        """
        let files = ProtonDriveProvider.files(from: json, parent: RemotePath("/my-files"))
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files.first?.byteCount, 12)
        XCTAssertEqual(files.first?.path.value, "/my-files/été.txt")
        XCTAssertEqual(files.last?.isDirectory, true)
    }

    func testCaptureDrainsBothPipesBeforeExit() async {
        let output = await ProcessRunner.runCapturingOutput(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "head -c 200000 /dev/zero; head -c 200000 /dev/zero >&2"], timeout: .seconds(5))
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.standardOutput.utf8.count, 200000)
        XCTAssertEqual(output.errorOutput.utf8.count, 200000)
    }

    func testInstalledCLIConnectionWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["FIL_TEST_PROTON"] == "1" else { throw XCTSkip("Compte Proton requis") }
        let provider = ProtonDriveProvider(connection: RemoteConnection(protocol: .protonDrive))
        let home = try await provider.connect()
        XCTAssertEqual(home, RemotePath("/my-files"))
        _ = try await provider.list(home)
    }

    func testRealUploadReplacementAndDownload() async throws {
        guard ProcessInfo.processInfo.environment["FIL_TEST_PROTON_WRITE"] == "1" else { throw XCTSkip("Écriture Proton explicitement activée") }
        let provider = ProtonDriveProvider(connection: RemoteConnection(protocol: .protonDrive))
        let remote = RemotePath("/my-files/Fil-test-\(UUID().uuidString)")
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }
        let folder = RemoteFile(name: remote.name, path: remote, kind: .directory)
        try await provider.makeDirectory(remote)
        do {
            let source = local.appendingPathComponent("source différente.txt")
            let target = remote.appending("été final.txt")
            let first = Data("Première version".utf8)
            try first.write(to: source)
            try await TransferRunner.replaceFile(source, at: target, via: provider)
            let entries = try await provider.list(remote)
            XCTAssertEqual(entries.map(\.name), [target.name])
            let second = Data("Deuxième version — contenu remplacé".utf8)
            try second.write(to: source)
            try await TransferRunner.replaceFile(source, at: target, via: provider)
            let updated = try await provider.list(remote)
            XCTAssertEqual(updated.map(\.name), [target.name])
            let file = try XCTUnwrap(updated.first)
            XCTAssertEqual(file.byteCount, Int64(second.count))
            let download = local.appendingPathComponent("download.filpart")
            try await provider.download(file, to: download, resumingAt: 0) { _ in }
            XCTAssertEqual(try Data(contentsOf: download), second)
            let bulkDestination = local.appendingPathComponent("bulk")
            try FileManager.default.createDirectory(at: bulkDestination, withIntermediateDirectories: true)
            try await TransferRunner.download(folder, into: bulkDestination, via: provider, ledger: TransferLedger(), report: TransferReport { _ in })
            XCTAssertEqual(try Data(contentsOf: bulkDestination.appendingPathComponent(remote.name).appendingPathComponent(target.name)), second)
        } catch {
            try? await provider.delete(folder)
            throw error
        }
        try await provider.delete(folder)
    }
}
