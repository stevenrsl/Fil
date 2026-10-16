import CCurl
import XCTest
@testable import Fil

final class FTPListingTests: XCTestCase {
    private let directory = RemotePath("/pub")

    func testMLSD() {
        let text = """
        type=cdir;modify=20261012153000;perm=el; .
        type=pdir;modify=20261012153000;perm=el; ..
        type=dir;modify=20261011080000;perm=flcdmpe; photos 2026
        type=file;size=1234567;modify=20261012153000.123;perm=adfrw; rapport; final.pdf
        type=OS.unix=slink:/var/www;modify=20261012153000; www
        """
        let files = FTPListing.parseMLSD(text, in: directory)
        XCTAssertEqual(files.map(\.name), ["photos 2026", "rapport; final.pdf", "www"])
        XCTAssertEqual(files[0].kind, .directory)
        XCTAssertEqual(files[0].path.value, "/pub/photos 2026")
        XCTAssertEqual(files[1].byteCount, 1_234_567)
        XCTAssertEqual(files[1].modifiedAt, Date(timeIntervalSince1970: 1_791_819_000))
        XCTAssertEqual(files[2].kind, .link)
        XCTAssertTrue(files[2].isSymbolicLink)
    }

    func testUnixLIST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10))!
        let text = """
        total 12
        drwxr-xr-x    2 user     group        4096 Oct 12 15:30 dossier
        -rw-r--r--    1 user     group     1234567 Jan  3 09:15 nom avec  espaces.txt
        -rw-r--r--    1 user     group          10 Mar  1  2024 ancien.log
        lrwxrwxrwx    1 user     group          11 Jan  5 10:00 www -> /var/www
        -rw-r--r--    1 1001     1234 Jan  5 10:00 sans-groupe.bin
        drwxr-xr-x    2 user     group        4096 Jan  5 10:00 .
        """
        let files = FTPListing.parseLIST(text, in: directory, now: now, calendar: calendar)
        XCTAssertEqual(files.map(\.name), ["dossier", "nom avec  espaces.txt", "ancien.log", "www", "sans-groupe.bin"])
        XCTAssertEqual(files[0].kind, .directory)
        // « Oct 12 » sans année, vu en janvier 2026 : c'était octobre 2025.
        XCTAssertEqual(calendar.component(.year, from: files[0].modifiedAt!), 2025)
        XCTAssertEqual(calendar.component(.year, from: files[1].modifiedAt!), 2026)
        XCTAssertEqual(files[1].byteCount, 1_234_567)
        XCTAssertEqual(calendar.component(.year, from: files[2].modifiedAt!), 2024)
        XCTAssertEqual(files[3].kind, .link)
        XCTAssertEqual(files[4].byteCount, 1234)
    }

    func testDOSLIST() {
        let text = """
        10-12-26  03:30PM       <DIR>          Mes documents
        01-02-25  09:05AM              2048 note.txt
        """
        let files = FTPListing.parseLIST(text, in: .root)
        XCTAssertEqual(files.map(\.name), ["Mes documents", "note.txt"])
        XCTAssertEqual(files[0].kind, .directory)
        XCTAssertEqual(files[1].byteCount, 2048)
        XCTAssertEqual(Calendar.current.component(.hour, from: files[0].modifiedAt!), 15)
    }

    func testLatin1ListingStillDecodes() {
        let data = Data([0x63, 0x61, 0x66, 0xE9])
        XCTAssertEqual(FTPListing.decode(data), "café")
    }
}

final class FTPAddressTests: XCTestCase {
    func testURLsUseAbsolutePaths() {
        let address = FTPAddress(connection: RemoteConnection(host: "ftp.exemple.fr", protocol: .ftp))
        XCTAssertEqual(address.rootURL, "ftp://ftp.exemple.fr:21/")
        XCTAssertEqual(address.directoryURL(.root), "ftp://ftp.exemple.fr:21/%2F/")
        XCTAssertEqual(address.directoryURL(RemotePath("/home/moi/été 2026")), "ftp://ftp.exemple.fr:21/%2Fhome/moi/%C3%A9t%C3%A9%202026/")
        XCTAssertEqual(address.fileURL(RemotePath("/a.txt")), "ftp://ftp.exemple.fr:21/%2F/a.txt")
        XCTAssertEqual(address.fileURL(RemotePath("/www/#1?.txt")), "ftp://ftp.exemple.fr:21/%2Fwww/%231%3F.txt")
    }

    func testImplicitFTPSOnPort990() {
        XCTAssertEqual(FTPAddress(connection: RemoteConnection(host: "h", port: 990, protocol: .ftps)).scheme, "ftps")
        XCTAssertEqual(FTPAddress(connection: RemoteConnection(host: "h", protocol: .ftps)).scheme, "ftp")
        XCTAssertEqual(FTPProvider(connection: RemoteConnection(host: "h", protocol: .ftps), password: "").security, .explicit)
        XCTAssertEqual(FTPProvider(connection: RemoteConnection(host: "h", port: 990, protocol: .ftps), password: "").security, .implicit)
        XCTAssertEqual(FTPProvider(connection: RemoteConnection(host: "h", protocol: .ftp), password: "").security, .none)
    }

    func testIPv6HostIsBracketed() {
        XCTAssertEqual(FTPAddress(connection: RemoteConnection(host: "::1", protocol: .ftp)).rootURL, "ftp://[::1]:21/")
    }

    func testErrorsAreReadable() {
        func describe(_ code: CURLcode, _ response: Int = 0) -> ProviderError {
            FTPProvider.describe(CurlFailure(code: code, response: response, detail: ""), host: "h", port: 21, subject: "x")
        }
        XCTAssertEqual(describe(CURLE_LOGIN_DENIED), .authenticationFailed)
        XCTAssertEqual(describe(CURLE_COULDNT_RESOLVE_HOST), .hostNotFound("h"))
        XCTAssertEqual(describe(CURLE_PEER_FAILED_VERIFICATION), .certificateUntrusted)
        XCTAssertEqual(describe(CURLE_USE_SSL_FAILED), .tlsUnavailable)
        XCTAssertEqual(describe(CURLE_FTP_COULDNT_RETR_FILE, 550), .notFound("x"))
        XCTAssertEqual(describe(CURLE_COULDNT_CONNECT), .connectionRefused(host: "h", port: 21))
        XCTAssertTrue(FTPProvider.isRejectedCommand(CurlFailure(code: CURLE_FTP_COULDNT_RETR_FILE, response: 500, detail: "")))
        XCTAssertFalse(FTPProvider.isRejectedCommand(CurlFailure(code: CURLE_REMOTE_ACCESS_DENIED, response: 550, detail: "")))
    }
}

final class WebDAVListingTests: XCTestCase {
    func testPrefixedNamespacesAndRootStripping() throws {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:response>
            <d:href>/remote.php/dav/files/moi/Documents/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
          </d:response>
          <d:response>
            <d:href>/remote.php/dav/files/moi/Documents/Factures%202026/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><d:getlastmodified>Mon, 12 Oct 2026 15:30:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
            <d:propstat><d:prop><d:getcontentlength/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
          </d:response>
          <d:response>
            <d:href>https://cloud.exemple.fr/remote.php/dav/files/moi/Documents/caf%C3%A9.txt</d:href>
            <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>42</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
          </d:response>
        </d:multistatus>
        """
        let files = try WebDAVListing.parse(Data(xml.utf8), rootPath: "/remote.php/dav/files/moi", directory: RemotePath("/Documents"))
        XCTAssertEqual(files.map(\.name), ["Factures 2026", "café.txt"])
        XCTAssertEqual(files[0].kind, .directory)
        XCTAssertEqual(files[0].path.value, "/Documents/Factures 2026")
        XCTAssertEqual(files[0].modifiedAt, Date(timeIntervalSince1970: 1_791_819_000))
        XCTAssertNil(files[0].byteCount)
        XCTAssertEqual(files[1].byteCount, 42)
    }

    func testApacheStyleUppercasePrefixAtRoot() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:" xmlns:lp1="DAV:">
        <D:response><D:href>/</D:href><D:propstat><D:prop><lp1:resourcetype><D:collection/></lp1:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        <D:response><D:href>/notes.md</D:href><D:propstat><D:prop><lp1:resourcetype/><lp1:getcontentlength>7</lp1:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        </D:multistatus>
        """
        let files = try WebDAVListing.parse(Data(xml.utf8), rootPath: "", directory: .root)
        XCTAssertEqual(files.map(\.path.value), ["/notes.md"])
        XCTAssertEqual(files.first?.byteCount, 7)
    }

    func testHrefOutsideRootIsIgnored() {
        XCTAssertNil(WebDAVListing.remotePath(forHref: "/autre/chose", rootPath: "/dav"))
        XCTAssertEqual(WebDAVListing.remotePath(forHref: "/dav/a%20b/", rootPath: "/dav"), RemotePath("/a b"))
    }

    func testGarbageIsAReadableError() {
        XCTAssertThrowsError(try WebDAVListing.parse(Data("<html><body>".utf8), rootPath: "", directory: .root)) { error in
            XCTAssertEqual((error as? ProviderError)?.errorDescription, "Le serveur a renvoyé une réponse WebDAV illisible.")
        }
    }

    func testRequestURLs() {
        let provider = WebDAVProvider(connection: RemoteConnection(host: "cloud.exemple.fr", protocol: .webdav, username: "moi", path: "/remote.php/dav/files/moi"), password: "x")
        XCTAssertEqual(provider.root.absoluteString, "https://cloud.exemple.fr/remote.php/dav/files/moi")
        XCTAssertEqual(provider.url(for: RemotePath("/a b/c#d"), directory: true).absoluteString, "https://cloud.exemple.fr/remote.php/dav/files/moi/a%20b/c%23d/")
        XCTAssertEqual(provider.url(for: .root, directory: true).absoluteString, "https://cloud.exemple.fr/remote.php/dav/files/moi/")
        let kdrive = WebDAVProvider(connection: RemoteConnection(host: "123456", port: 8443, protocol: .kdrive, username: "moi@exemple.fr"), password: "x")
        XCTAssertEqual(kdrive.root.absoluteString, "https://123456.connect.kdrive.infomaniak.com:8443")
    }
}

final class SFTPPacketTests: XCTestCase {
    func testRequestFraming() {
        let packet = SFTPCodec.packet(.opendir, id: 7) { $0.string("/srv") }
        XCTAssertEqual([UInt8](packet), [0, 0, 0, 13, 11, 0, 0, 0, 7, 0, 0, 0, 4, 0x2F, 0x73, 0x72, 0x76])
    }

    func testPacketsArriveInPieces() throws {
        var writer = SFTPWriter()
        writer.byte(SFTPPacketType.status.rawValue)
        writer.uint32(3)
        writer.uint32(SFTPStatus.endOfFile)
        writer.string("End of file")
        writer.string("")
        var framed = SFTPWriter()
        framed.string(writer.bytes)

        var buffer = Data(framed.bytes.prefix(5))
        XCTAssertNil(try SFTPCodec.nextPacket(from: &buffer))
        buffer.append(framed.bytes.dropFirst(5))
        let payload = try XCTUnwrap(SFTPCodec.nextPacket(from: &buffer))
        XCTAssertTrue(buffer.isEmpty)
        let decoded = try SFTPCodec.decode(payload)
        XCTAssertEqual(decoded.id, 3)
        XCTAssertEqual(decoded.response, .status(SFTPStatus(code: 1, message: "End of file")))
    }

    func testNameResponseWithAttributes() throws {
        var writer = SFTPWriter()
        writer.byte(SFTPPacketType.name.rawValue)
        writer.uint32(9)
        writer.uint32(1)
        writer.string("été.txt")
        writer.string("-rw-r--r-- 1 moi moi 5 Oct 12 15:30 été.txt")
        writer.attributes(SFTPAttributes(size: 5, uid: 501, gid: 20, permissions: 0o100644, accessTime: 1, modificationTime: 1_791_819_000))
        let decoded = try SFTPCodec.decode(writer.bytes)
        guard case .name(let entries) = decoded.response else { return XCTFail("NAME attendu") }
        XCTAssertEqual(entries.first?.filename, "été.txt")
        XCTAssertEqual(entries.first?.attributes.size, 5)
        XCTAssertFalse(entries.first?.attributes.isDirectory ?? true)
        XCTAssertEqual(entries.first?.attributes.modifiedAt, Date(timeIntervalSince1970: 1_791_819_000))
    }

    func testExtendedAttributesAreSkipped() throws {
        var writer = SFTPWriter()
        writer.byte(SFTPPacketType.attrs.rawValue)
        writer.uint32(1)
        writer.uint32(SFTPAttributes.permissionsFlag | SFTPAttributes.extendedFlag)
        writer.uint32(0o040755)
        writer.uint32(1)
        writer.string("acl@exemple")
        writer.string("x")
        guard case .attributes(let attributes) = try SFTPCodec.decode(writer.bytes).response else { return XCTFail() }
        XCTAssertTrue(attributes.isDirectory)
    }

    func testShellNoiseIsDetected() {
        var buffer = Data("Bienvenue sur le serveur\n".utf8)
        XCTAssertThrowsError(try SFTPCodec.nextPacket(from: &buffer)) { error in
            guard case SFTPWireError.oversized = error else { return XCTFail("\(error)") }
        }
    }
}

final class SSHCommandTests: XCTestCase {
    func testArguments() {
        let connection = RemoteConnection(host: "exemple.fr", port: 2222, protocol: .sftp, username: "moi")
        let arguments = SSHCommand.arguments(for: connection)
        XCTAssertEqual(Array(arguments.suffix(4)), ["-s", "--", "exemple.fr", "sftp"])
        XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"), "un serveur inconnu n'est jamais accepté en silence")
        XCTAssertFalse(arguments.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertTrue(arguments.contains("UpdateHostKeys=no"), "ssh n'écrit rien dans les fichiers de l'utilisateur de son propre chef")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-p")! + 1], "2222")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-l")! + 1], "moi")
    }

    func testDefaultPortAndUserAreLeftToSSHConfig() {
        let arguments = SSHCommand.arguments(for: RemoteConnection(host: "alias", protocol: .sftp))
        XCTAssertFalse(arguments.contains("-p"))
        XCTAssertFalse(arguments.contains("-l"))
    }

    func testEnvironmentCarriesNoSecret() {
        let id = UUID()
        let environment = SSHCommand.environment(base: ["SSH_AUTH_SOCK": "/tmp/agent"], askpass: "/Applications/Fil", connectionID: id)
        XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(environment[Askpass.connectionVariable], id.uuidString)
        XCTAssertEqual(environment["SSH_AUTH_SOCK"], "/tmp/agent")
    }

    func testExitMessages() {
        func describe(_ text: String) -> ProviderError {
            SSHCommand.describeExit(status: 255, errorOutput: text, host: "h", port: 22)
        }
        XCTAssertEqual(describe("moi@h: Permission denied (publickey,password)."), .server("Le serveur refuse l'identifiant, le mot de passe ou la clé SSH."))
        XCTAssertEqual(describe("ssh: Could not resolve hostname h: nodename nor servname provided"), .hostNotFound("h"))
        XCTAssertEqual(describe("ssh: connect to host h port 22: Connection refused"), .connectionRefused(host: "h", port: 22))
        XCTAssertEqual(describe("@@@@\nWARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\nHost key verification failed."), .hostKeyChanged("h"))
        XCTAssertEqual(describe("Warning: Permanently added 'h' to the list of known hosts.\nsubsystem request failed on channel 0"), .server("Le serveur n'accepte pas SFTP pour ce compte."))
        XCTAssertEqual(describe(""), .connectionLost)
    }
}

final class AskpassTests: XCTestCase {
    func testAnswersPasswordPromptsFromTheSecretStore() {
        let secrets = MemorySecretStore()
        let id = UUID()
        try? secrets.save(password: "s3cret", for: id, label: "Test")
        let environment = [Askpass.connectionVariable: id.uuidString]
        XCTAssertNil(Askpass.runIfRequested(environment: [:], arguments: ["Fil"], secrets: secrets))
        XCTAssertEqual(Askpass.runIfRequested(environment: environment, arguments: ["Fil", "Are you sure you want to continue connecting (yes/no)?"], secrets: secrets), 1)
        XCTAssertEqual(Askpass.runIfRequested(environment: [Askpass.connectionVariable: UUID().uuidString], arguments: ["Fil", "moi@h's password:"], secrets: secrets), 1)
        XCTAssertTrue(Askpass.isSecretPrompt("(moi@h) Password:"))
        XCTAssertTrue(Askpass.isSecretPrompt("Enter passphrase for key '/Users/moi/.ssh/id_ed25519':"))
        XCTAssertFalse(Askpass.isSecretPrompt("Verification code:"))
    }
}
