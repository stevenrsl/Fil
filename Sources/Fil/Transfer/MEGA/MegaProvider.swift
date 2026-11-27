import Foundation
import os

#if os(macOS)

/// MEGA par MEGAcmd. Le chiffrement reste celui de MEGA, fait par son outil : Fil ne voit que des chemins.
/// Les téléchargements arrivent dans un dossier caché à côté de leur destination, puis sont renommés :
/// aucune copie, rien hors du volume d'arrivée.
final class MegaProvider: RemoteFileProvider, OneTimeCodeAccepting, @unchecked Sendable {
    let connection: RemoteConnection
    let canResumeUploads = false
    /// Le serveur MEGAcmd mène lui-même ses transferts : deux à la fois suffisent à remplir le lien sans l'encombrer.
    let parallelFiles = 2
    private let password: String
    private let runner: any MegaCommandRunning
    private let base: RemotePath
    private let code = OSAllocatedUnfairLock(initialState: "")
    /// Intervalle entre deux lectures de `mega-transfers`.
    private let poll: Duration

    static let quick: Duration = .seconds(120)
    /// `whoami` répond tout de suite d'un serveur vivant : au-delà, il est figé.
    static let check: Duration = .seconds(20)
    static let transfer: Duration = .seconds(24 * 60 * 60)

    init(connection: RemoteConnection, password: String, runner: any MegaCommandRunning = MegaCMD(), poll: Duration = .seconds(1)) {
        self.connection = connection
        self.poll = poll
        self.password = password
        self.runner = runner
        let configured = connection.path.trimmingCharacters(in: .whitespacesAndNewlines)
        self.base = configured.isEmpty ? .root : RemotePath(configured)
    }

    func useOneTimeCode(_ value: String) { code.withLock { $0 = value } }

    private var email: String { connection.username.trimmingCharacters(in: .whitespacesAndNewlines) }

    func connect() async throws -> RemotePath {
        try await ensureLoggedIn()
        // La mise à jour automatique de MEGAcmd lance un processus fils qui reste coincé avec la prise du
        // serveur (vu en usage réel) : la copie de MEGAcmd utilisée par Fil ne se met pas à jour seule.
        _ = try? await runner.run("exec", ["update", "--auto=off"], timeout: Self.check)
        _ = try await list(base)
        return base
    }

    /// Reprend la session de MEGAcmd si c'est le bon compte, sinon se connecte avec le mot de passe du trousseau.
    private func ensureLoggedIn() async throws {
        let whoami: ProcessRunner.CapturedOutput
        do {
            whoami = try await runner.run("whoami", [], timeout: Self.check)
        } catch ProviderError.timedOut {
            // Serveur figé : on le remplace une fois, puis on redemande.
            await runner.restartServer()
            whoami = try await runner.run("whoami", [], timeout: Self.quick)
        }
        if whoami.status == 0, let current = Self.account(from: whoami.standardOutput) {
            guard current.caseInsensitiveCompare(email) == .orderedSame else {
                throw ProviderError.server("MEGAcmd est déjà connecté au compte \(current). Déconnecte-le avec « mega-logout » dans le Terminal, ou indique cet e-mail dans la connexion.")
            }
            return
        }
        guard !password.isEmpty else { throw ProviderError.server("Ajoute le mot de passe de ton compte MEGA.") }
        let typedCode = code.withLock { value in defer { value = "" }; return value }
        let arguments = (typedCode.isEmpty ? [] : ["--auth-code=" + typedCode]) + [email, password]
        let login = try await runner.run("login", arguments, timeout: Self.quick)
        // Une demande de code laissée sans réponse peut finir avec le statut 0 : on lit la sortie d'abord.
        let text = (login.standardOutput + "\n" + login.errorOutput).lowercased()
        let mentionsCode = ["authentication app", "authentication code", "two-factor", "multifactor", "multi-factor"].contains { text.contains($0) }
        if mentionsCode || (login.status != 0 && !typedCode.isEmpty && text.contains("incorrect authentication")) {
            throw ProviderError.oneTimeCodeRequired(service: "MEGA", rejected: !typedCode.isEmpty)
        }
        guard login.status != 0 else { return }
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
        try await transfer("get", [file.path.value, landing.path + "/"], direction: "--only-downloads", name: file.name, total: file.byteCount, progress: progress)
        let received = landing.appendingPathComponent(file.name)
        let size = LocalFile.size(of: received) ?? -1
        guard size >= 0, file.byteCount.map({ $0 == size }) ?? true else {
            throw ProviderError.incomplete(name: file.name, received: max(size, 0), expected: file.byteCount ?? 0)
        }
        try fileManager.removeItemIfExists(at: destination)
        try fileManager.moveItem(at: received, to: destination)
        progress(size)
    }

    func upload(_ source: URL, to destination: RemotePath, resumingAt offset: Int64, progress: @escaping ProgressHandler) async throws {
        let total = LocalFile.size(of: source) ?? 0
        // Sans `-c` : une destination absente devient le nom du fichier envoyé, jamais un dossier.
        try await transfer("put", [source.path, destination.value], direction: "--only-uploads", name: destination.name, total: total, progress: progress)
        let arrived = try await size(of: destination)
        guard arrived == total else { throw ProviderError.incomplete(name: destination.name, received: arrived ?? 0, expected: total) }
        progress(total)
    }

    /// Met le transfert dans la file du serveur MEGAcmd (`-q`), puis le suit par son numéro dans `mega-transfers`.
    /// Le client `mega-put` n'affiche aucune progression hors d'un terminal, et le transfert appartient au
    /// serveur : il continue même si le client s'arrête. Suivre le serveur est donc la seule mesure fiable.
    private func transfer(_ command: String, _ arguments: [String], direction: String, name: String, total: Int64?, progress: @escaping ProgressHandler) async throws {
        let queued = try await runner.run(command, ["-q", "--print-tag-at-start"] + arguments, timeout: Self.quick)
        guard queued.status == 0, let tag = Self.tag(from: queued.standardOutput + "\n" + queued.errorOutput) else {
            throw Self.error(from: queued, subject: name)
        }
        do {
            var missing = 0
            while true {
                try await Task.sleep(for: poll)
                let listing = try await runner.run("transfers", [direction, "--show-completed", "--output-cols=TAG,PROGRESS,STATE", "--col-separator=|"], timeout: Self.check)
                guard let row = Self.transfers(from: listing.standardOutput).first(where: { $0.tag == tag }) else {
                    // Sorti de la liste : l'appelant vérifie ce qui est arrivé.
                    missing += 1
                    if missing >= 3 { return }
                    continue
                }
                missing = 0
                if let fraction = row.fraction, let total, total > 0 { progress(Int64((Double(total) * fraction).rounded(.down))) }
                switch row.state {
                case "COMPLETED": return
                case "FAILED": throw ProviderError.server("MEGA a refusé le transfert de « \(name) ». Réessaie ; si cela recommence, vérifie l'espace libre de ton compte.")
                case "CANCELLED": throw ProviderError.server("Le transfert de « \(name) » a été annulé dans MEGAcmd.")
                default: continue
                }
            }
        } catch {
            if error is CancellationError || Task.isCancelled {
                // Annulé dans Fil : le serveur l'arrête aussi, sinon il continuerait seul.
                let runner = runner
                Task.detached { _ = try? await runner.run("transfers", ["-c", tag], timeout: Self.check) }
                throw CancellationError()
            }
            throw error
        }
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

    // MARK: Lecture des sorties de MEGAcmd

    /// « Upload started: Tag = 42 » → « 42 ».
    static func tag(from output: String) -> String? {
        let range = NSRange(output.startIndex..., in: output)
        guard let match = tagPattern.firstMatch(in: output, range: range),
              let value = Range(match.range(at: 1), in: output) else { return nil }
        return String(output[value])
    }

    private static let tagPattern = try! NSRegularExpression(pattern: #"Tag\s*=\s*(-?[0-9]+)"#, options: .caseInsensitive)

    struct TransferRow: Equatable {
        let tag: String
        let fraction: Double?
        let state: String
    }

    /// Sortie de `mega-transfers --output-cols=TAG,PROGRESS,STATE --col-separator=|` :
    /// « 42|48.78% of   11.00 GB|ACTIVE ». L'en-tête et les lignes inconnues sont ignorés.
    static func transfers(from output: String) -> [TransferRow] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 3, !columns[0].isEmpty, columns[0].allSatisfy({ $0.isNumber || $0 == "-" }) else { return nil }
            return TransferRow(tag: columns[0], fraction: fraction(in: columns[1]), state: columns[2].uppercased())
        }
    }

    private static let percent = try! NSRegularExpression(pattern: #"([0-9]+(?:[.,][0-9]+)?)\s*%"#)

    /// Premier pourcentage d'un texte de MEGAcmd, entre 0 et 1.
    static func fraction(in text: String) -> Double? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = percent.firstMatch(in: text, range: range),
              let number = Range(match.range(at: 1), in: text),
              let value = Double(text[number].replacingOccurrences(of: ",", with: ".")) else { return nil }
        return min(max(value / 100, 0), 1)
    }

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
