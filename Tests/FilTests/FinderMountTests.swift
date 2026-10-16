import XCTest
@testable import Fil

/// Monteur simulé : retient la demande, renvoie un point de montage fictif ou une erreur.
final class FakeFinderVolumes: FinderVolumes, @unchecked Sendable {
    private let lock = NSLock()
    private var _mounts: [(url: URL, user: String, password: String)] = []
    private var _revealed: [URL] = []
    var failure: Error?
    /// Pause avant de répondre, pour un serveur lent.
    var delay: Duration = .zero
    let mountPoint = URL(fileURLWithPath: "/Volumes/dav", isDirectory: true)

    var mounts: [(url: URL, user: String, password: String)] { lock.withLock { _mounts } }
    var revealed: [URL] { lock.withLock { _revealed } }

    func mount(_ url: URL, user: String, password: String) async throws -> URL {
        lock.withLock { _mounts.append((url, user, password)) }
        try await Task.sleep(for: delay)
        if let failure { throw failure }
        return mountPoint
    }

    @MainActor func reveal(_ folder: URL) {
        lock.withLock { _revealed.append(folder) }
    }
}

final class FinderMountTargetTests: XCTestCase {
    func testWebDAVMountsItsRootWithTrailingSlash() {
        let connection = RemoteConnection(host: "dav.exemple.fr", port: 8443, protocol: .webdav, path: "/partage/équipe")
        XCTAssertEqual(FinderMount.target(for: connection), .url(URL(string: "https://dav.exemple.fr:8443/partage/%C3%A9quipe/")!))
    }

    func testKDriveNumericIDResolvesToInfomaniakHost() {
        let connection = RemoteConnection(host: "123456", protocol: .kdrive)
        XCTAssertEqual(FinderMount.target(for: connection), .url(URL(string: "https://123456.connect.kdrive.infomaniak.com/")!))
    }

    func testOnlyWebDAVProtocolsAreSupported() {
        XCTAssertEqual(RemoteProtocol.allCases.filter(FinderMount.isSupported), [.webdav, .kdrive])
        guard case .blocked = FinderMount.target(for: RemoteConnection(host: "h", protocol: .ftp)) else {
            return XCTFail("FTP ne doit pas se monter")
        }
    }

    func testCertificateTrustedOnlyInFilIsRefusedWithAReason() {
        let connection = RemoteConnection(host: "nas.local", protocol: .webdav, trustedCertificate: TrustedCertificate(sha256: "ab", subject: "nas"))
        XCTAssertEqual(FinderMount.target(for: connection), .blocked("Ce serveur n'est approuvé que dans Fil. Le Finder ne reconnaît pas son certificat."))
    }

    func testFolderInsideMountPointFollowsRemotePath() {
        let folder = FinderMount.folder(for: RemotePath("/site/www"), in: URL(fileURLWithPath: "/Volumes/dav", isDirectory: true))
        XCTAssertEqual(folder.path, "/Volumes/dav/site/www")
    }

    func testMountErrorsAreReadable() {
        XCTAssertEqual(FinderMountError(status: EAUTH, host: "h").errorDescription, "« h » refuse l'identifiant ou le mot de passe dans le Finder.")
        XCTAssertEqual(FinderMountError(status: 999, host: "h").errorDescription, "Le Finder n'a pas pu monter « h » (code 999).")
    }
}

@MainActor
final class BrowserFinderTests: XCTestCase {
    private func makeBrowser(_ connection: RemoteConnection, volumes: FakeFinderVolumes?) -> BrowserModel {
        let provider = MockProvider(connection: connection, files: ["/site/www/index.html": "x"])
        return BrowserModel(connection: connection, provider: provider, home: RemotePath("/site/www"), transfers: TransferQueue(),
                            finder: volumes.map { FinderAccess(volumes: $0, password: "s3cret") }) {
            FileManager.default.temporaryDirectory
        }
    }

    func testOpensShownFolderInsideMountedVolume() async {
        let volumes = FakeFinderVolumes()
        let browser = makeBrowser(RemoteConnection(name: "Dav", host: "dav.test", protocol: .webdav, username: " steven "), volumes: volumes)
        XCTAssertTrue(browser.canOpenInFinder)
        browser.openInFinder()
        XCTAssertEqual(browser.waitingPhrase, "Montage de « Dav » dans le Finder…")
        await waitUntil("révélé") { !volumes.revealed.isEmpty }
        XCTAssertEqual(volumes.mounts.first?.url, URL(string: "https://dav.test/")!)
        XCTAssertEqual(volumes.mounts.first?.user, "steven")
        XCTAssertEqual(volumes.mounts.first?.password, "s3cret")
        XCTAssertEqual(volumes.revealed.first?.path, "/Volumes/dav/site/www")
        await waitUntil("libéré") { browser.activity == nil }
        XCTAssertNil(browser.notice)
    }

    func testMountFailureBecomesNotice() async {
        let volumes = FakeFinderVolumes()
        volumes.failure = FinderMountError(status: ETIMEDOUT, host: "dav.test")
        let browser = makeBrowser(RemoteConnection(host: "dav.test", protocol: .webdav), volumes: volumes)
        browser.openInFinder()
        await waitUntil("refus") { browser.notice != nil }
        XCTAssertEqual(browser.notice, "« dav.test » ne répond pas. Le Finder n'a pas pu le monter.")
        XCTAssertNil(browser.activity)
        XCTAssertTrue(volumes.revealed.isEmpty)
    }

    func testSlowMountSaysTheServerIsTakingTimeThenStillReveals() async {
        let volumes = FakeFinderVolumes()
        volumes.delay = .milliseconds(300)
        let browser = makeBrowser(RemoteConnection(name: "kDrive", host: "123", protocol: .kdrive), volumes: volumes)
        browser.finderPatience = .milliseconds(50)
        browser.openInFinder()
        await waitUntil("phrase de lenteur") { browser.activity?.contains("met du temps") == true }
        XCTAssertEqual(browser.waitingPhrase, "« 123.connect.kdrive.infomaniak.com » met du temps à répondre. Le montage continue…")
        await waitUntil("révélé") { !volumes.revealed.isEmpty }
        await waitUntil("libéré") { browser.activity == nil }
    }

    func testUnavailableWithoutAccessOrForOtherProtocols() {
        XCTAssertFalse(makeBrowser(RemoteConnection(host: "dav.test", protocol: .webdav), volumes: nil).canOpenInFinder)
        XCTAssertFalse(makeBrowser(RemoteConnection(host: "ftp.test", protocol: .ftp), volumes: FakeFinderVolumes()).canOpenInFinder)
    }
}
