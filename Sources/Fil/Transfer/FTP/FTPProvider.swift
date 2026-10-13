import CCurl
import Foundation

/// FTP et FTPS par la libcurl de macOS.
/// FTPS explicite (`AUTH TLS`) sur tout port sauf 990, implicite sur 990.
/// La navigation réutilise une seule connexion ; chaque transfert ouvre la sienne.
final class FTPProvider: RemoteFileProvider, @unchecked Sendable {
    enum Security: Equatable { case none, explicit, implicit }

    let connection: RemoteConnection
    let address: FTPAddress
    private let password: String
    /// Autorités de certification supplémentaires. Réservé aux tests d'intégration.
    private let certificateAuthorities: String?

    // Confinés à `browsing`.
    private let browsing = DispatchQueue(label: "fil.ftp.browsing", qos: .userInitiated)
    private var browsingHandle: CurlHandle?
    private var supportsMLSD = true

    private static let transfers = DispatchQueue(label: "fil.ftp.transfers", qos: .utility, attributes: .concurrent)

    init(connection: RemoteConnection, password: String, certificateAuthorities: String? = nil) {
        self.connection = connection
        self.password = password
        self.certificateAuthorities = certificateAuthorities
        self.address = FTPAddress(connection: connection)
    }

    var security: Security {
        guard connection.protocol == .ftps else { return .none }
        return connection.port == 990 ? .implicit : .explicit
    }

    // MARK: RemoteFileProvider

    func connect() async throws -> RemotePath {
        let home: RemotePath = try await run(on: browsing) { flag in
            let handle = try self.sharedHandle()
            let transfer = CurlTransfer(cancellation: flag)
            self.prepare(handle, url: self.address.rootURL)
            handle.set(CURLOPT_NOBODY, 1)
            try self.check(handle.perform(transfer), transfer, subject: self.connection.resolvedHost)
            return RemotePath(handle.string(CURLINFO_FTP_ENTRY_PATH) ?? "/")
        }
        return RemotePath.resolve(connection.path, from: home)
    }

    func list(_ directory: RemotePath) async throws -> [RemoteFile] {
        let url = address.directoryURL(directory)
        return try await run(on: browsing) { flag in
            let handle = try self.sharedHandle()
            if self.supportsMLSD {
                let transfer = CurlTransfer(cancellation: flag)
                self.prepare(handle, url: url)
                handle.set(CURLOPT_CUSTOMREQUEST, "MLSD")
                switch handle.perform(transfer) {
                case .success:
                    return FTPListing.parseMLSD(FTPListing.decode(transfer.received), in: directory)
                case .failure(let failure) where Self.isRejectedCommand(failure):
                    self.supportsMLSD = false
                case .failure(let failure):
                    throw self.readable(failure, transfer: transfer, subject: directory.name)
                }
            }
            let transfer = CurlTransfer(cancellation: flag)
            self.prepare(handle, url: url)
            try self.check(handle.perform(transfer), transfer, subject: directory.name)
            return FTPListing.parseLIST(FTPListing.decode(transfer.received), in: directory)
        }
    }

    func download(_ file: RemoteFile, to destination: URL, progress: @escaping ProgressHandler) async throws {
        let url = address.fileURL(file.path)
        try await run(on: Self.transfers) { flag in
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw ProviderError.server("Impossible de créer « \(destination.lastPathComponent) » sur ce Mac.")
            }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            let handle = try CurlHandle()
            let transfer = CurlTransfer(output: output, progress: progress, cancellation: flag)
            self.prepare(handle, url: url)
            try self.check(handle.perform(transfer), transfer, subject: file.name)
        }
    }

    func upload(_ source: URL, to destination: RemotePath, progress: @escaping ProgressHandler) async throws {
        let url = address.fileURL(destination)
        try await run(on: Self.transfers) { flag in
            let size = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64 ?? -1
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let handle = try CurlHandle()
            let transfer = CurlTransfer(input: input, progress: progress, cancellation: flag)
            self.prepare(handle, url: url)
            handle.set(CURLOPT_UPLOAD, 1)
            handle.set(CURLOPT_INFILESIZE_LARGE, offset: size)
            try self.check(handle.perform(transfer), transfer, subject: destination.name)
        }
    }

    func makeDirectory(_ path: RemotePath) async throws {
        try await command("MKD", path)
    }

    func delete(_ file: RemoteFile) async throws {
        try await deleteTree(
            file,
            list: { try await self.list($0) },
            removeFile: { try await self.command("DELE", $0) },
            removeDirectory: { try await self.command("RMD", $0) }
        )
    }

    // MARK: Mécanique

    /// Commande brute envoyée après connexion. Les chemins sont absolus : l'état `CWD` ne compte pas.
    private func command(_ verb: String, _ path: RemotePath) async throws {
        guard !path.value.contains(where: { $0 == "\r" || $0 == "\n" }) else {
            throw ProviderError.server("Ce nom contient un retour à la ligne : le serveur FTP ne peut pas le traiter.")
        }
        try await run(on: browsing) { flag in
            let handle = try self.sharedHandle()
            let transfer = CurlTransfer(cancellation: flag)
            self.prepare(handle, url: self.address.rootURL)
            handle.set(CURLOPT_NOBODY, 1)
            handle.set(CURLOPT_QUOTE, lines: ["\(verb) \(path.value)"])
            try self.check(handle.perform(transfer), transfer, subject: path.name)
        }
    }

    private func sharedHandle() throws -> CurlHandle {
        if let browsingHandle { return browsingHandle }
        let handle = try CurlHandle()
        browsingHandle = handle
        return handle
    }

    private func prepare(_ handle: CurlHandle, url: String) {
        handle.reset()
        handle.set(CURLOPT_URL, url)
        handle.set(CURLOPT_PROTOCOLS_STR, "ftp,ftps")
        let user = connection.username.trimmingCharacters(in: .whitespacesAndNewlines)
        handle.set(CURLOPT_USERNAME, user.isEmpty ? "anonymous" : user)
        handle.set(CURLOPT_PASSWORD, user.isEmpty ? "fil@localhost" : password)
        handle.set(CURLOPT_NOSIGNAL, 1)
        handle.set(CURLOPT_CONNECTTIMEOUT, 15)
        handle.set(CURLOPT_SERVER_RESPONSE_TIMEOUT, 30)
        handle.set(CURLOPT_LOW_SPEED_LIMIT, 1)
        handle.set(CURLOPT_LOW_SPEED_TIME, 60)
        handle.set(CURLOPT_TCP_KEEPALIVE, 1)
        handle.set(CURLOPT_FTP_FILEMETHOD, Int(CURLFTPMETHOD_SINGLECWD.rawValue))
        // Ignore l'adresse annoncée en mode passif : les serveurs derrière un NAT l'annoncent souvent fausse.
        handle.set(CURLOPT_FTP_SKIP_PASV_IP, 1)
        if security != .none {
            handle.set(CURLOPT_USE_SSL, Int(CURLUSESSL_ALL.rawValue))
        }
        if let certificateAuthorities {
            handle.set(CURLOPT_CAINFO, certificateAuthorities)
        }
    }

    private func run<T: Sendable>(on queue: DispatchQueue, _ work: @escaping @Sendable (CancellationFlag) throws -> T) async throws -> T {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result { try work(flag) })
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    private func check(_ result: Result<Void, CurlFailure>, _ transfer: CurlTransfer, subject: String) throws {
        if case .failure(let failure) = result {
            throw readable(failure, transfer: transfer, subject: subject)
        }
    }

    private func readable(_ failure: CurlFailure, transfer: CurlTransfer, subject: String) -> Error {
        if failure.code == CURLE_ABORTED_BY_CALLBACK, transfer.cancellation.isCancelled { return CancellationError() }
        if let local = transfer.localError { return local }
        return Self.describe(failure, host: connection.resolvedHost, port: connection.port, subject: subject)
    }

    /// `MLSD` refusé par le serveur : on bascule sur `LIST` une fois pour toutes.
    static func isRejectedCommand(_ failure: CurlFailure) -> Bool {
        let rejectedCodes: [CURLcode] = [CURLE_FTP_COULDNT_RETR_FILE, CURLE_QUOTE_ERROR, CURLE_WEIRD_SERVER_REPLY]
        return rejectedCodes.contains(failure.code) || (500...504).contains(failure.response)
    }

    static func describe(_ failure: CurlFailure, host: String, port: Int, subject: String) -> ProviderError {
        if failure.response == 421 {
            return .server("Le serveur a fermé la connexion : il limite peut-être le nombre de connexions simultanées.")
        }
        if failure.response == 530 { return .authenticationFailed }
        switch failure.code {
        case CURLE_COULDNT_RESOLVE_HOST: return .hostNotFound(host)
        case CURLE_COULDNT_CONNECT: return .connectionRefused(host: host, port: port)
        case CURLE_OPERATION_TIMEDOUT: return .timedOut
        case CURLE_LOGIN_DENIED: return .authenticationFailed
        case CURLE_USE_SSL_FAILED: return .tlsUnavailable
        case CURLE_PEER_FAILED_VERIFICATION: return .certificateUntrusted
        case CURLE_SSL_CONNECT_ERROR:
            return .server("La négociation chiffrée avec le serveur a échoué. Vérifie le port : FTPS implicite utilise 990, explicite 21.")
        case CURLE_REMOTE_ACCESS_DENIED: return .accessDenied(subject)
        case CURLE_REMOTE_FILE_NOT_FOUND: return .notFound(subject)
        case CURLE_FTP_COULDNT_RETR_FILE:
            return failure.response == 550 ? .notFound(subject) : .server("Le serveur refuse d'envoyer « \(subject) » (réponse \(failure.response)).")
        case CURLE_UPLOAD_FAILED, CURLE_QUOTE_ERROR:
            switch failure.response {
            case 552: return .server("Il n'y a plus assez d'espace sur le serveur.")
            case 553: return .server("Le serveur refuse le nom « \(subject) ».")
            case 550: return .server("Le serveur refuse l'opération sur « \(subject) » : élément introuvable, déjà présent ou droits insuffisants.")
            default: return .server("Le serveur refuse l'opération sur « \(subject) » (réponse \(failure.response)).")
            }
        case CURLE_WRITE_ERROR: return .server("Impossible d'écrire « \(subject) » sur ce Mac.")
        case CURLE_READ_ERROR: return .server("Impossible de lire « \(subject) » sur ce Mac.")
        case CURLE_SEND_ERROR, CURLE_RECV_ERROR, CURLE_GOT_NOTHING, CURLE_PARTIAL_FILE: return .connectionLost
        case CURLE_FTP_WEIRD_PASV_REPLY, CURLE_FTP_WEIRD_227_FORMAT, CURLE_FTP_CANT_GET_HOST, CURLE_FTP_ACCEPT_FAILED, CURLE_FTP_PORT_FAILED, CURLE_FTP_ACCEPT_TIMEOUT:
            return .server("Le serveur n'arrive pas à ouvrir le canal de données. Un pare-feu bloque peut-être le mode passif.")
        case CURLE_WEIRD_SERVER_REPLY:
            return .server("Le serveur ne répond pas comme un serveur FTP. Vérifie le port et le protocole.")
        default:
            return .server("Erreur FTP : \(failure.detail) (code \(failure.code.rawValue)).")
        }
    }
}

/// Construction des URL libcurl. Les chemins sont absolus (`%2F` en tête) et `SINGLECWD`
/// fait un seul `CWD` vers le dossier, puis la commande sur le nom seul.
struct FTPAddress: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    init(connection: RemoteConnection) {
        scheme = connection.protocol == .ftps && connection.port == 990 ? "ftps" : "ftp"
        host = connection.resolvedHost
        port = connection.port
    }

    private var authority: String {
        let host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(host):\(port)"
    }

    var rootURL: String { authority + "/" }

    func directoryURL(_ path: RemotePath) -> String {
        authority + "/" + directoryPart(path) + "/"
    }

    func fileURL(_ path: RemotePath) -> String {
        authority + "/" + directoryPart(path.parent ?? .root) + "/" + Self.encode(path.name)
    }

    private func directoryPart(_ path: RemotePath) -> String {
        "%2F" + path.components.map(Self.encode).joined(separator: "/")
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,=:@")

    static func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: unreserved) ?? component
    }
}
