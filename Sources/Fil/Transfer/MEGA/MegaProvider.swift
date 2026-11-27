import Foundation

#if os(macOS)

/// Lance une commande MEGAcmd (`mega-<commande>`). Derrière un protocole pour les tests.
protocol MegaCommandRunning: Sendable {
    func run(_ command: String, _ arguments: [String], timeout: Duration) async throws -> ProcessRunner.CapturedOutput
}

/// MEGAcmd, l'outil officiel de MEGA, installé par l'utilisateur. Ses commandes parlent à `mega-cmd-server`,
/// qui garde la session ouverte entre deux appels : Fil ne se reconnecte pas à chaque liste.
struct MegaCMD: MegaCommandRunning {
    static let missing = ProviderError.server("MEGAcmd, l'outil officiel de MEGA, n'est pas installé. Installe-le depuis mega.io/cmd, puis reconnecte-toi.")

    /// Dossier qui contient `mega-exec` et les scripts `mega-*`.
    static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/Applications/MEGAcmd.app/Contents/MacOS", home + "/Applications/MEGAcmd.app/Contents/MacOS"]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0 + "/mega-exec") }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func run(_ command: String, _ arguments: [String], timeout: Duration) async throws -> ProcessRunner.CapturedOutput {
        guard let directory = Self.directory() else { throw Self.missing }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        let output = await ProcessRunner.runCapturingOutput(directory.appendingPathComponent("mega-" + command), arguments: arguments, environment: environment, timeout: timeout)
        try Task.checkCancellation()
        return output
    }
}

/// MEGA par MEGAcmd. Le chiffrement reste celui de MEGA, fait par son outil : Fil ne voit que des chemins.
/// Les téléchargements arrivent dans un dossier caché à côté de leur destination, puis sont renommés :
/// aucune copie, rien hors du volume d'arrivée.
final class MegaProvider: RemoteFileProvider, @unchecked Sendable {
    let connection: RemoteConnection
    let canResumeUploads = false
    /// Le serveur MEGAcmd mène lui-même ses transferts : deux à la fois suffisent à remplir le lien sans l'encombrer.
    let parallelFiles = 2
    private let password: String
    private let runner: any MegaCommandRunning
    private let base: RemotePath

    static let quick: Duration = .seconds(120)
    static let transfer: Duration = .seconds(24 * 60 * 60)

    init(connection: RemoteConnection, password: String, runner: any MegaCommandRunning = MegaCMD()) {
        self.connection = connection
        self.password = password
        self.runner = runner
        let configured = connection.path.trimmingCharacters(in: .whitespacesAndNewlines)
        self.base = configured.isEmpty ? .root : RemotePath(configured)
    }

    private var email: String { connection.username.trimmingCharacters(in: .whitespacesAndNewlines) }

    func connect() async throws -> RemotePath {
        try await ensureLoggedIn()
        _ = try await list(base)
        return base
    }

    /// Reprend la session de MEGAcmd si c'est le bon compte, sinon se connecte avec le mot de passe du trousseau.
    private func ensureLoggedIn() async throws {
        let whoami = try await runner.run("whoami", [], timeout: Self.quick)
        if whoami.status == 0, let current = Self.account(from: whoami.standardOutput) {
            guard current.caseInsensitiveCompare(email) == .orderedSame else {
                throw ProviderError.server("MEGAcmd est déjà connecté au compte \(current). Déconnecte-le avec « mega-logout » dans le Terminal, ou indique cet e-mail dans la connexion.")
            }
            return
        }
        guard !password.isEmpty else { throw ProviderError.server("Ajoute le mot de passe de ton compte MEGA.") }
        let login = try await runner.run("login", [email, password], timeout: Self.quick)
        guard login.status != 0 else { return }
        let text = Self.message(login).lowercased()
        if text.contains("auth-code") || text.contains("two-factor") || text.contains("2fa") || text.contains("multi-factor") {
            throw ProviderError.server("Ton compte MEGA demande un code de double authentification. Connecte-toi une fois dans le Terminal avec « mega-login \(email) » : MEGAcmd garde la session et Fil s'en sert ensuite.")
        }
        throw ProviderError.authenticationFailed
    }

    func list(_ directory: RemotePath) async throws -> [RemoteFile] {
        let output = try await runner.run("ls", ["-l", "--time-format=ISO6081_WITH_TIME", directory.value], timeout: Self.quick)
        guard output.status == 0 else { throw Self.error(from: output, subject: directory.name) }
        return Self.files(from: output.standardOutput, parent: directory)
    }

    func download(_ file: RemoteFile, to destination: URL, resumingAt offset: Int64, progress: @escaping ProgressHandler) async throws {
        // MEGAcmd ne reprend pas un fichier local entamé : on repart de zéro (le contrat le permet).
        let fileManager = FileManager.default
        let folder = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let landing = folder.appendingPathComponent(".fil-mega-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: landing, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: landing) }
        let monitor = Self.monitor(landing, progress: progress)
        defer { monitor.cancel() }
        let output = try await runner.run("get", [file.path.value, landing.path + "/"], timeout: Self.transfer)
        guard output.status == 0 else { throw Self.error(from: output, subject: file.name) }
        let received = landing.appendingPathComponent(file.name)
        guard fileManager.fileExists(atPath: received.path) else {
            throw ProviderError.incomplete(name: file.name, received: 0, expected: file.byteCount ?? 0)
        }
        try fileManager.removeItemIfExists(at: destination)
        try fileManager.moveItem(at: received, to: destination)
        progress(LocalFile.size(of: destination) ?? 0)
    }

    func upload(_ source: URL, to destination: RemotePath, resumingAt offset: Int64, progress: @escaping ProgressHandler) async throws {
        // Sans `-c` : une destination absente devient le nom du fichier envoyé, jamais un dossier.
        let output = try await runner.run("put", [source.path, destination.value], timeout: Self.transfer)
        guard output.status == 0 else { throw Self.error(from: output, subject: destination.name) }
        progress(LocalFile.size(of: source) ?? 0)
    }

    func size(of path: RemotePath) async throws -> Int64? {
        do {
            return try await list(path.parent ?? .root).first { $0.path == path }?.byteCount
        } catch ProviderError.notFound {
            return nil
        }
    }

    private func exists(_ path: RemotePath) async throws -> Bool {
        do {
            return try await list(path.parent ?? .root).contains { $0.path == path }
        } catch ProviderError.notFound {
            return false
        }
    }

    /// MEGA accepte deux fichiers du même nom dans un dossier : `mv` sur un nom pris en ferait un doublon.
    /// L'ancien est donc mis de côté d'abord, remis en place si le renommage échoue, puis mis à la corbeille.
    func move(_ source: RemotePath, to destination: RemotePath) async throws {
        guard try await exists(destination) else { return try await rename(source, to: destination) }
        let backup = (destination.parent ?? .root).appending(destination.name + ".filbak")
        try await rename(destination, to: backup)
        do {
            try await rename(source, to: destination)
        } catch {
            try? await rename(backup, to: destination)
            throw error
        }
        try? await trash(backup)
    }

    private func rename(_ source: RemotePath, to destination: RemotePath) async throws {
        let output = try await runner.run("mv", [source.value, destination.value], timeout: Self.quick)
        guard output.status == 0 else { throw Self.error(from: output, subject: source.name) }
    }

    func makeDirectory(_ path: RemotePath) async throws {
        let output = try await runner.run("mkdir", ["-p", path.value], timeout: Self.quick)
        guard output.status == 0 else { throw Self.error(from: output, subject: path.name) }
    }

    /// Dans la corbeille de MEGA (`//bin`), comme dans l'interface de MEGA : rien n'est effacé pour de bon.
    func delete(_ file: RemoteFile) async throws {
        try await trash(file.path)
    }

    private func trash(_ path: RemotePath) async throws {
        let output = try await runner.run("mv", [path.value, "//bin"], timeout: Self.quick)
        guard output.status == 0 else { throw Self.error(from: output, subject: path.name) }
    }

    private static func monitor(_ directory: URL, progress: @escaping ProgressHandler) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                progress(bytes(in: directory))
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }

    private static func bytes(in directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    // MARK: Lecture des sorties de MEGAcmd

    /// « Account e-mail: moi@exemple.fr » → l'adresse.
    static func account(from output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased().contains("e-mail") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.contains("@") { return value }
        }
        return nil
    }

    private static let row = try! NSRegularExpression(
        pattern: #"^([d\-][a-z\-]{3})\s+(\S+)\s+(\S+)\s+(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}|\d{2}[A-Za-z]{3}\d{4} \d{2}:\d{2}:\d{2})\s+(.+)$"#
    )

    /// Sortie de `mega-ls -l` : drapeaux, versions, taille, date, nom. L'en-tête et les lignes inconnues sont ignorés.
    static func files(from output: String, parent: RemotePath) -> [RemoteFile] {
        output.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = row.firstMatch(in: line, range: range), match.numberOfRanges == 6 else { return nil }
            func group(_ index: Int) -> String { Range(match.range(at: index), in: line).map { String(line[$0]) } ?? "" }
            let name = group(5)
            guard !name.isEmpty, name != ".", name != ".." else { return nil }
            let isDirectory = group(1).hasPrefix("d")
            return RemoteFile(
                name: name,
                path: parent.appending(name),
                kind: isDirectory ? .directory : .file,
                byteCount: isDirectory ? nil : Int64(group(3)),
                modifiedAt: date(group(4))
            )
        }
    }

    private static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = text.contains("T") ? "yyyy-MM-dd'T'HH:mm:ss" : "ddMMMyyyy HH:mm:ss"
        return formatter.date(from: text)
    }

    /// Dernière ligne utile de MEGAcmd, sans son préfixe « [err: …] ».
    static func message(_ output: ProcessRunner.CapturedOutput) -> String {
        let lines = (output.errorOutput + "\n" + output.standardOutput)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard var line = lines.first(where: { $0.lowercased().contains("err") }) ?? lines.last else { return "" }
        if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
            line = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    static func error(from output: ProcessRunner.CapturedOutput, subject: String) -> ProviderError {
        let text = message(output)
        let lower = text.lowercased()
        if lower.contains("not logged in") { return .server("MEGAcmd n'est plus connecté à ton compte. Ferme la connexion et rouvre-la.") }
        if lower.contains("couldn't find") || lower.contains("not found") || lower.contains("no such") { return .notFound(subject) }
        if lower.contains("access denied") || lower.contains("permission") || lower.contains("eaccess") { return .accessDenied(subject) }
        if lower.contains("over quota") || lower.contains("overquota") || lower.contains("storage quota") {
            return .server("Ton espace MEGA est plein : « \(subject) » n'a pas pu être envoyé.")
        }
        return .server(text.isEmpty ? "MEGAcmd a échoué pour « \(subject) »." : text)
    }
}

#endif
