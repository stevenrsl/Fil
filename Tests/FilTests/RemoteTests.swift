import XCTest
@testable import Fil

final class RemoteTests: XCTestCase {
    func testDefaultPortsFollowProtocol() {
        XCTAssertEqual(RemoteConnection.defaultPort(for: .ftp), 21)
        XCTAssertEqual(RemoteConnection.defaultPort(for: .ftps), 21)
        XCTAssertEqual(RemoteConnection.defaultPort(for: .sftp), 22)
        XCTAssertEqual(RemoteConnection.defaultPort(for: .webdav), 443)
        XCTAssertEqual(RemoteConnection(protocol: .ftp).port, 21)
    }

    func testKDriveIdentifierExpandsToWebDAVHost() {
        let connection = RemoteConnection(host: " 123456 ", protocol: .kdrive)
        XCTAssertEqual(connection.resolvedHost, "123456.connect.kdrive.infomaniak.com")
        XCTAssertEqual(RemoteConnection(host: "123456", protocol: .webdav).resolvedHost, "123456")
    }

    func testSummaryOmitsDefaultPort() {
        XCTAssertEqual(RemoteConnection(host: "exemple.fr", protocol: .sftp, username: "moi").summary, "SFTP · moi@exemple.fr")
        XCTAssertEqual(RemoteConnection(host: "exemple.fr", port: 2222, protocol: .sftp).summary, "SFTP · exemple.fr:2222")
    }

    func testLegacyConnectionWithoutPathDecodes() throws {
        let json = #"[{"id":"7B1F7C55-2F0F-4D1B-9B53-3D3A5A1E8C11","name":"Archive","host":"exemple.fr","port":22,"protocol":"sftp","username":"moi"}]"#
        let decoded = try JSONDecoder().decode([RemoteConnection].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.first?.path, "")
        XCTAssertEqual(decoded.first?.username, "moi")
    }

    func testPhaseExposesItsConnection() {
        let connection = RemoteConnection(host: "exemple.fr")
        XCTAssertNil(Phase.choosing.connection)
        XCTAssertEqual(Phase.browsing(connection).connection, connection)
        XCTAssertTrue(Phase.connecting(connection).isConnecting)
        XCTAssertEqual(Phase.failed(connection, reason: "x").connection, connection)
    }
}

final class ConnectionStoreTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        // Nom fixe, vidé à chaque fois : aucun domaine de préférences ne s'accumule.
        suite = "FilTests.\(Self.self)"
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testConnectionsRoundTripThroughStore() {
        let store = ConnectionStore(defaults: defaults)
        let connection = RemoteConnection(name: "Archive", host: "example.org", protocol: .sftp, path: "/srv")
        store.save(.init(connections: [connection], lastUsedID: connection.id))

        let loaded = store.load()
        XCTAssertEqual(loaded.connections, [connection])
        XCTAssertEqual(loaded.lastUsedID, connection.id)
        XCTAssertEqual(loaded.version, ConnectionStore.currentVersion)
    }

    func testVersionOneIsMigratedOnce() throws {
        let legacy = RemoteConnection(name: "Ancien", host: "ftp.exemple.fr", protocol: .ftp)
        defaults.set(try JSONEncoder().encode([legacy]), forKey: ConnectionStore.legacyKeyV1)

        let store = ConnectionStore(defaults: defaults)
        XCTAssertEqual(store.load().connections, [legacy])
        XCTAssertNil(defaults.data(forKey: ConnectionStore.legacyKeyV1))
        XCTAssertNotNil(defaults.data(forKey: ConnectionStore.key))
        XCTAssertEqual(store.load().connections, [legacy])
    }

    func testFavoritesNeverContainSecrets() throws {
        let store = ConnectionStore(defaults: defaults)
        store.save(.init(connections: [RemoteConnection(name: "Site", host: "exemple.fr", username: "moi")]))
        let raw = String(decoding: try XCTUnwrap(defaults.data(forKey: ConnectionStore.key)), as: UTF8.self)
        XCTAssertFalse(raw.lowercased().contains("password"))
    }

    func testEmptyStoreLoadsNothing() {
        XCTAssertEqual(ConnectionStore(defaults: defaults).load().connections, [])
    }
}

final class RemotePathTests: XCTestCase {
    func testEmptyPathIsRoot() {
        XCTAssertEqual(RemotePath("").value, "/")
        XCTAssertTrue(RemotePath("").isRoot)
    }

    func testNormalisation() {
        XCTAssertEqual(RemotePath("a//b/").value, "/a/b")
        XCTAssertEqual(RemotePath("/a/./b/../c").value, "/a/c")
        XCTAssertEqual(RemotePath("/../..").value, "/")
    }

    func testParentNameAndLineage() {
        let path = RemotePath("/srv/www/site")
        XCTAssertEqual(path.name, "site")
        XCTAssertEqual(path.parent, RemotePath("/srv/www"))
        XCTAssertNil(RemotePath.root.parent)
        XCTAssertEqual(path.lineage.map(\.value), ["/", "/srv", "/srv/www", "/srv/www/site"])
        XCTAssertEqual(path.appending("index.html").value, "/srv/www/site/index.html")
    }

    func testPrefix() {
        XCTAssertTrue(RemotePath("/a/b").hasPrefix(RemotePath("/a")))
        XCTAssertFalse(RemotePath("/ab").hasPrefix(RemotePath("/a")))
        XCTAssertTrue(RemotePath("/ab").hasPrefix(.root))
    }

    func testResolveUserInput() {
        let home = RemotePath("/home/moi")
        XCTAssertEqual(RemotePath.resolve("", from: home), home)
        XCTAssertEqual(RemotePath.resolve("www", from: home).value, "/home/moi/www")
        XCTAssertEqual(RemotePath.resolve("~/www", from: home).value, "/home/moi/www")
        XCTAssertEqual(RemotePath.resolve("/var/www", from: home).value, "/var/www")
    }
}

final class RemoteAddressTests: XCTestCase {
    func testFullSFTPURL() throws {
        let address = try XCTUnwrap(RemoteAddress(parsing: "sftp://moi@exemple.fr:2222/var/www"))
        XCTAssertEqual(address, RemoteAddress(protocol: .sftp, host: "exemple.fr", port: 2222, username: "moi", path: "/var/www"))
    }

    func testWebDAVAndKDriveURLs() throws {
        let nextcloud = try XCTUnwrap(RemoteAddress(parsing: "https://cloud.exemple.fr/remote.php/dav/files/moi"))
        XCTAssertEqual(nextcloud.protocol, .webdav)
        XCTAssertEqual(nextcloud.path, "/remote.php/dav/files/moi")
        XCTAssertNil(nextcloud.port)

        let kdrive = try XCTUnwrap(RemoteAddress(parsing: "https://123456.connect.kdrive.infomaniak.com/"))
        XCTAssertEqual(kdrive.protocol, .kdrive)
        XCTAssertNil(kdrive.path)
    }

    func testShortForms() throws {
        XCTAssertEqual(RemoteAddress(parsing: "moi@exemple.fr"), RemoteAddress(host: "exemple.fr", username: "moi"))
        XCTAssertEqual(RemoteAddress(parsing: "exemple.fr:2121"), RemoteAddress(host: "exemple.fr", port: 2121))
        XCTAssertEqual(RemoteAddress(parsing: "exemple.fr/pub"), RemoteAddress(host: "exemple.fr", path: "/pub"))
    }

    func testPlainHostAndUnknownSchemeAreLeftAlone() {
        XCTAssertNil(RemoteAddress(parsing: "exemple.fr"))
        XCTAssertNil(RemoteAddress(parsing: "  "))
        XCTAssertNil(RemoteAddress(parsing: "gopher://exemple.fr"))
        XCTAssertNil(RemoteAddress(parsing: "moi@"))
        XCTAssertNil(RemoteAddress(parsing: "fe80::1"))
    }

    func testApplyKeepsUnspecifiedFields() {
        var connection = RemoteConnection(host: "", protocol: .sftp, username: "garde", path: "/garde")
        connection.apply(RemoteAddress(protocol: .ftps, host: "ftp.exemple.fr"))
        XCTAssertEqual(connection.protocol, .ftps)
        XCTAssertEqual(connection.port, 21)
        XCTAssertEqual(connection.username, "garde")
        XCTAssertEqual(connection.path, "/garde")
    }
}

final class ReadinessTests: XCTestCase {
    func testNoConnection() {
        XCTAssertEqual(Readiness.connecting(nil).reason, "Choisis une connexion pour continuer.")
    }

    func testHostIsRequiredAndClean() {
        XCTAssertEqual(Readiness.connecting(RemoteConnection(host: "")).reason, "Ajoute l'adresse du serveur.")
        XCTAssertEqual(Readiness.connecting(RemoteConnection(host: "a b")).reason, "L'adresse du serveur ne doit pas contenir d'espace.")
        XCTAssertTrue(Readiness.connecting(RemoteConnection(host: "exemple.fr")).isReady)
    }

    func testPortRange() {
        let reason = Readiness.connecting(RemoteConnection(host: "exemple.fr", port: 70_000)).reason
        XCTAssertEqual(reason?.hasPrefix("Le port doit être compris entre 1 et 65"), true)
    }

    func testKDriveNeedsAnEmail() {
        XCTAssertEqual(Readiness.connecting(RemoteConnection(host: "123456", protocol: .kdrive)).reason, "Ajoute l'adresse e-mail de ton compte Infomaniak.")
    }

    func testProtonDriveIsHonestlyUnavailable() {
        let readiness = Readiness.connecting(RemoteConnection(host: "x", protocol: .protonDrive))
        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(readiness.reason, RemoteProtocol.protonDrive.unavailableReason)
    }

    func testAnonymousFTPIsAllowed() {
        XCTAssertTrue(Readiness.connecting(RemoteConnection(host: "ftp.exemple.fr", protocol: .ftp)).isReady)
    }
}

final class FormatTests: XCTestCase {
    /// Le français sépare par des espaces insécables : on compare sans eux.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    func testBytes() {
        XCTAssertEqual(plain(Format.bytes(1_234_567)), "1,2 Mo")
        XCTAssertEqual(Format.bytes(0), "0 octet")
    }

    func testCountsAndPlurals() {
        XCTAssertEqual(plain(Format.count(65_535)), "65 535")
        XCTAssertEqual(Format.items(0), "0 élément")
        XCTAssertEqual(Format.items(1), "1 élément")
        XCTAssertEqual(Format.items(2), "2 éléments")
        XCTAssertEqual(Format.files(3), "3 fichiers")
    }

    func testDurations() {
        XCTAssertEqual(Format.duration(0.4), "moins d'une seconde")
        XCTAssertEqual(plain(Format.duration(130)), "2 min et 10 s")
        XCTAssertEqual(plain(Format.duration(4)), "4 s")
    }

    func testRateAndProgress() {
        XCTAssertEqual(plain(Format.rate(2_000_000)), "2 Mo/s")
        XCTAssertEqual(plain(Format.progress(1_000_000, of: 4_000_000)), "1 Mo sur 4 Mo")
    }

    func testDateOmitsCurrentYear() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 12))!
        let sameYear = calendar.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 9, minute: 5))!
        let lastYear = calendar.date(from: DateComponents(year: 2025, month: 3, day: 4))!
        XCTAssertFalse(Format.date(sameYear, now: now, calendar: calendar).contains("2026"))
        XCTAssertTrue(Format.date(lastYear, now: now, calendar: calendar).contains("2025"))
    }
}
