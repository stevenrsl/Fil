import XCTest
@testable import Fil

/// Faux MEGAcmd : chaque commande reçoit une réponse écrite par le test, et les appels sont notés.
private final class FakeMega: MegaCommandRunning, @unchecked Sendable {
    typealias Reply = (_ command: String, _ arguments: [String]) -> ProcessRunner.CapturedOutput
    private let lock = NSLock()
    private var _calls: [[String]] = []
    let reply: Reply

    init(_ reply: @escaping Reply) { self.reply = reply }

    var calls: [[String]] { lock.withLock { _calls } }

    func run(_ command: String, _ arguments: [String], timeout: Duration) async throws -> ProcessRunner.CapturedOutput {
        lock.withLock { _calls.append([command] + arguments) }
        return reply(command, arguments)
    }
}

private func ok(_ out: String = "") -> ProcessRunner.CapturedOutput { .init(status: 0, standardOutput: out, errorOutput: "") }
private func fail(_ err: String) -> ProcessRunner.CapturedOutput { .init(status: 1, standardOutput: "", errorOutput: err) }

final class MegaTests: XCTestCase {
    private let connection = RemoteConnection(name: "MEGA", protocol: .mega, username: "moi@exemple.fr")

    func testModelNeedsAnEmailButNoServerAddress() {
        var mega = RemoteConnection(protocol: .mega)
        XCTAssertFalse(RemoteProtocol.mega.hasServerAddress)
        XCTAssertEqual(mega.resolvedHost, "")
        XCTAssertEqual(Readiness.connecting(mega).reasons, ["Ajoute l'adresse e-mail de ton compte MEGA."])
        mega.username = "moi@exemple.fr"
        XCTAssertTrue(Readiness.connecting(mega).isReady)
        XCTAssertEqual(mega.summary, "MEGA · moi@exemple.fr")
    }

    func testListingParsesLongFormat() {
        let output = """
        FLAGS VERS          SIZE                DATE      NAME
        d---     -             -  2026-11-20T22:25:03      Cloud de Steven
        ----     1       1048576  2026-11-21T08:00:00      rapport final.pdf
        -ep-     3            12  21Nov2026 09:30:00       notes.txt
        garbage line
        """
        let files = MegaProvider.files(from: output, parent: RemotePath("/Travail"))
        XCTAssertEqual(files.map(\.name), ["Cloud de Steven", "rapport final.pdf", "notes.txt"])
        XCTAssertTrue(files[0].isDirectory)
        XCTAssertNil(files[0].byteCount)
        XCTAssertEqual(files[1].byteCount, 1_048_576)
        XCTAssertEqual(files[1].path.value, "/Travail/rapport final.pdf")
        XCTAssertNotNil(files[1].modifiedAt)
        XCTAssertNotNil(files[2].modifiedAt)
    }

    func testReusesTheSessionOfTheSameAccount() async throws {
        let fake = FakeMega { command, _ in command == "whoami" ? ok("Account e-mail: Moi@Exemple.fr\n") : ok() }
        let start = try await MegaProvider(connection: connection, password: "", runner: fake).connect()
        XCTAssertEqual(start, .root)
        XCTAssertFalse(fake.calls.contains { $0.first == "login" })
    }

    func testLogsInWithTheKeychainPasswordWhenLoggedOut() async throws {
        let fake = FakeMega { command, _ in command == "whoami" ? fail("[err: 12:00:00] Not logged in.") : ok() }
        _ = try await MegaProvider(connection: connection, password: "secret", runner: fake).connect()
        XCTAssertEqual(fake.calls.first { $0.first == "login" }, ["login", "moi@exemple.fr", "secret"])
    }

    func testOtherAccountAndTwoFactorAreExplained() async {
        let other = FakeMega { _, _ in ok("Account e-mail: autre@exemple.fr") }
        do {
            _ = try await MegaProvider(connection: connection, password: "x", runner: other).connect()
            XCTFail("Un autre compte ne doit pas être utilisé")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("autre@exemple.fr"))
        }
        let twoFactor = FakeMega { command, _ in command == "whoami" ? fail("Not logged in.") : fail("Login failed: --auth-code required") }
        do {
            _ = try await MegaProvider(connection: connection, password: "x", runner: twoFactor).connect()
            XCTFail("La double authentification doit être dite")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("mega-login moi@exemple.fr"))
        }
        let refused = FakeMega { command, _ in command == "whoami" ? fail("Not logged in.") : fail("Login failed: Failed access") }
        do {
            _ = try await MegaProvider(connection: connection, password: "x", runner: refused).connect()
            XCTFail("Un mot de passe refusé doit échouer")
        } catch {
            XCTAssertEqual(error as? ProviderError, .authenticationFailed)
        }
    }

    func testDownloadLandsNextToItsDestinationThenRenames() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FilMega-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = FakeMega { command, arguments in
            if command == "get" {
                let landing = URL(fileURLWithPath: arguments[1])
                XCTAssertEqual(landing.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
                try? Data("bonjour".utf8).write(to: landing.appendingPathComponent("a.txt"))
            }
            return ok()
        }
        let provider = MegaProvider(connection: connection, password: "", runner: fake)
        let destination = folder.appendingPathComponent("a.txt.filpart")
        try await provider.download(RemoteFile(name: "a.txt", path: RemotePath("/a.txt"), kind: .file, byteCount: 7), to: destination, resumingAt: 0) { _ in }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "bonjour")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["a.txt.filpart"])
    }

    func testMoveOntoAnExistingNameNeverLeavesADuplicate() async throws {
        let listing = "----  1  5  2026-11-21T08:00:00  site.zip\n----  1  5  2026-11-21T08:00:00  site.zip.filpart\n"
        let fake = FakeMega { command, _ in command == "ls" ? ok(listing) : ok() }
        try await MegaProvider(connection: connection, password: "", runner: fake).move(RemotePath("/site.zip.filpart"), to: RemotePath("/site.zip"))
        let moves = fake.calls.filter { $0.first == "mv" }
        XCTAssertEqual(moves, [
            ["mv", "/site.zip", "/site.zip.filbak"],
            ["mv", "/site.zip.filpart", "/site.zip"],
            ["mv", "/site.zip.filbak", "//bin"],
        ])
    }

    func testDeleteGoesToTheRubbishBin() async throws {
        let fake = FakeMega { _, _ in ok() }
        try await MegaProvider(connection: connection, password: "", runner: fake).delete(RemoteFile(name: "Vieux", path: RemotePath("/Vieux"), kind: .directory))
        XCTAssertEqual(fake.calls, [["mv", "/Vieux", "//bin"]])
    }

    func testErrorsAreReadable() {
        XCTAssertEqual(MegaProvider.error(from: fail("[err: 10:00:00] Couldn't find /x"), subject: "x"), .notFound("x"))
        XCTAssertEqual(MegaProvider.error(from: fail("[API:err: 10:00:00] Access denied"), subject: "x"), .accessDenied("x"))
        XCTAssertEqual(MegaProvider.account(from: "Account e-mail: moi@exemple.fr"), "moi@exemple.fr")
    }

    func testInstalledMEGAcmdWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["FIL_TEST_MEGA"] == "1",
              let email = ProcessInfo.processInfo.environment["FIL_TEST_MEGA_EMAIL"] else { throw XCTSkip("Compte MEGA et MEGAcmd requis") }
        let provider = MegaProvider(connection: RemoteConnection(protocol: .mega, username: email), password: ProcessInfo.processInfo.environment["FIL_TEST_MEGA_PASSWORD"] ?? "")
        let home = try await provider.connect()
        _ = try await provider.list(home)
    }
}
