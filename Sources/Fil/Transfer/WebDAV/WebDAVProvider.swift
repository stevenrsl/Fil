import Foundation

/// WebDAV en HTTPS, kDrive compris. Les chemins de navigation sont relatifs à la racine WebDAV.
final class WebDAVProvider: RemoteFileProvider {
    let connection: RemoteConnection
    let root: URL
    private let rootPath: String
    private let session: URLSession
    private let relay: WebDAVSessionRelay

    /// `root` remplace l'URL déduite de la connexion. Réservé aux tests d'intégration.
    init(connection: RemoteConnection, password: String, root: URL? = nil) {
        self.connection = connection
        let root = root ?? Self.defaultRoot(for: connection)
        self.root = root
        self.rootPath = root.path.removingPercentEncoding ?? root.path
        let user = connection.username.trimmingCharacters(in: .whitespacesAndNewlines)
        relay = WebDAVSessionRelay(credential: user.isEmpty ? nil : URLCredential(user: user, password: password, persistence: .forSession))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: relay, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    static func defaultRoot(for connection: RemoteConnection) -> URL {
        var host = connection.resolvedHost
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        let port = connection.port == 443 ? "" : ":\(connection.port)"
        let path = RemotePath(connection.path).components.map(encode).joined(separator: "/")
        return URL(string: "https://\(host)\(port)" + (path.isEmpty ? "" : "/\(path)"))
            ?? URL(string: "https://invalid.invalid")!
    }

    // MARK: RemoteFileProvider

    func connect() async throws -> RemotePath {
        _ = try await propfind(.root, depth: "0")
        return .root
    }

    func list(_ directory: RemotePath) async throws -> [RemoteFile] {
        let data = try await propfind(directory, depth: "1")
        return try WebDAVListing.parse(data, rootPath: rootPath, directory: directory)
    }

    func download(_ file: RemoteFile, to destination: URL, progress: @escaping ProgressHandler) async throws {
        let request = makeRequest(url(for: file.path, directory: false), method: "GET")
        let response = try await relay.run(session.downloadTask(with: request), destination: destination, progress: progress)
        try check(response, subject: file.name)
    }

    func upload(_ source: URL, to destination: RemotePath, progress: @escaping ProgressHandler) async throws {
        var request = makeRequest(url(for: destination, directory: false), method: "PUT")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let response = try await relay.run(session.uploadTask(with: request, fromFile: source), destination: nil, progress: progress)
        try check(response, subject: destination.name)
    }

    func makeDirectory(_ path: RemotePath) async throws {
        let (_, response) = try await session.data(for: makeRequest(url(for: path, directory: true), method: "MKCOL"))
        if (response as? HTTPURLResponse)?.statusCode == 405 { throw ProviderError.alreadyExists(path.name) }
        try check(response, subject: path.name)
    }

    func delete(_ file: RemoteFile) async throws {
        // DELETE sur une collection est récursif par définition (RFC 4918, 9.6.1).
        let (_, response) = try await session.data(for: makeRequest(url(for: file.path, directory: file.isDirectory), method: "DELETE"))
        try check(response, subject: file.name)
    }

    // MARK: Mécanique

    private func propfind(_ path: RemotePath, depth: String) async throws -> Data {
        var request = makeRequest(url(for: path, directory: true), method: "PROPFIND")
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
            """.utf8)
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 405 {
            throw ProviderError.server("Cette adresse ne répond pas comme un serveur WebDAV. Vérifie le chemin de la racine WebDAV.")
        }
        try check(response, subject: path.isRoot ? connection.resolvedHost : path.name)
        return data
    }

    func url(for path: RemotePath, directory: Bool) -> URL {
        var string = root.absoluteString
        while string.hasSuffix("/") { string.removeLast() }
        for component in path.components { string += "/" + Self.encode(component) }
        if directory { string += "/" }
        return URL(string: string) ?? root
    }

    private func makeRequest(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    private func check(_ response: URLResponse, subject: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.server("Le serveur a répondu de façon inattendue.")
        }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw ProviderError.authenticationFailed
        case 403: throw ProviderError.accessDenied(subject)
        case 404, 410: throw ProviderError.notFound(subject)
        case 409: throw ProviderError.server("Le dossier parent de « \(subject) » n'existe pas sur le serveur.")
        case 423: throw ProviderError.server("« \(subject) » est verrouillé par une autre application.")
        case 507: throw ProviderError.server("Il n'y a plus assez d'espace sur le serveur.")
        case 500..<600: throw ProviderError.server("Le serveur rencontre un problème (code \(http.statusCode)). Réessaie dans un instant.")
        default: throw ProviderError.server("Le serveur a répondu avec le code \(http.statusCode) pour « \(subject) ».")
        }
    }

    private static let pathCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@")

    static func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: pathCharacters) ?? component
    }
}

/// Délégué de session : authentification et progression des transferts.
/// La progression n'arrive qu'au délégué de session, pas à un délégué par tâche.
final class WebDAVSessionRelay: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Pending {
        let continuation: CheckedContinuation<URLResponse, Error>
        let destination: URL?
        let progress: ProgressHandler
        var moveError: Error?
    }

    private let credential: URLCredential?
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]

    init(credential: URLCredential?) {
        self.credential = credential
    }

    func run(_ task: URLSessionTask, destination: URL?, progress: @escaping ProgressHandler) async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    pending[task.taskIdentifier] = Pending(continuation: continuation, destination: destination, progress: progress)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func progressHandler(for task: URLSessionTask) -> ProgressHandler? {
        lock.withLock { pending[task.taskIdentifier]?.progress }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progressHandler(for: downloadTask)?(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progressHandler(for: task)?(totalBytesSent)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Le fichier temporaire disparaît au retour de cette méthode : on le déplace tout de suite.
        guard let http = downloadTask.response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let destination = lock.withLock({ pending[downloadTask.taskIdentifier]?.destination }) else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { pending[downloadTask.taskIdentifier]?.moveError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error {
            if (error as? URLError)?.code == .cancelled {
                entry.continuation.resume(throwing: CancellationError())
            } else {
                entry.continuation.resume(throwing: error)
            }
        } else if let moveError = entry.moveError {
            entry.continuation.resume(throwing: moveError)
        } else if let response = task.response {
            entry.continuation.resume(returning: response)
        } else {
            entry.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM:
            // Un seul essai : au-delà, le 401 remonte tel quel et devient « identifiant refusé ».
            if challenge.previousFailureCount == 0, let credential {
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.rejectProtectionSpace, nil)
            }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
