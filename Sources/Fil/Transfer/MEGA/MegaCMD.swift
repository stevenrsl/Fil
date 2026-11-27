import Foundation
import os

#if os(macOS)
import Security

/// Lance une commande MEGAcmd (`mega-<commande>`). Derrière un protocole pour les tests.
protocol MegaCommandRunning: Sendable {
    /// Une commande qui dépasse `timeout` lève `ProviderError.timedOut`.
    func run(_ command: String, _ arguments: [String], timeout: Duration) async throws -> ProcessRunner.CapturedOutput
    /// Arrête un serveur MEGAcmd qui ne répond plus ; la commande suivante en démarre un neuf.
    func restartServer() async
}


/// MEGAcmd, l'outil officiel de MEGA. Ses commandes parlent à un serveur (`mega-cmd`) qui garde la session
/// ouverte entre deux appels. Fil l'installe lui-même à la première connexion, dans son dossier
/// d'Application Support, après avoir vérifié la signature de Mega Limited : rien à faire hors de Fil.
struct MegaCMD: MegaCommandRunning {
    func run(_ command: String, _ arguments: [String], timeout: Duration) async throws -> ProcessRunner.CapturedOutput {
        let directory = try await MegaCMDInstaller.shared.directory()
        var environment = ProcessInfo.processInfo.environment
        // Les scripts `mega-*` appellent `mega-exec` par le PATH.
        environment["PATH"] = directory.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        // `mega-exec` démarre le serveur depuis /Applications, sinon depuis `./mega-cmd` : le dossier courant
        // est celui de MEGAcmd, et tous les chemins passés sont absolus.
        let clock = ContinuousClock()
        let started = clock.now
        let output = await ProcessRunner.runCapturingOutput(
            directory.appendingPathComponent("mega-" + command),
            arguments: arguments, environment: environment, currentDirectory: directory, timeout: timeout
        )
        try Task.checkCancellation()
        if output.status != 0, clock.now - started >= timeout - .milliseconds(500) { throw ProviderError.timedOut }
        return output
    }

    /// Un serveur peut survivre à sa propre fermeture (vu avec MEGAcmd 2.8.0 : « program end » écrit dans
    /// son journal, processus toujours là, prise ouverte, plus aucune réponse). On arrête tout `mega-cmd`
    /// de cet utilisateur : la session MEGA est sur le disque et reprend au démarrage suivant.
    func restartServer() async {
        let environment = ProcessInfo.processInfo.environment
        let user = String(getuid())
        let pkill = URL(fileURLWithPath: "/usr/bin/pkill")
        _ = await ProcessRunner.run(pkill, arguments: ["-U", user, "-x", "mega-cmd"], environment: environment, timeout: .seconds(5))
        try? await Task.sleep(for: .seconds(2))
        _ = await ProcessRunner.run(pkill, arguments: ["-9", "-U", user, "-x", "mega-cmd"], environment: environment, timeout: .seconds(5))
    }
}

/// Trouve MEGAcmd, ou le télécharge, le vérifie et l'installe. Un seul à la fois, même si plusieurs commandes attendent.
actor MegaCMDInstaller {
    static let shared = MegaCMDInstaller()
    static let downloadURL = URL(string: "https://mega.nz/MEGAcmdSetup.dmg")!
    /// Exigence de signature : MEGAcmd, Developer ID de Mega Limited (équipe T9RH74Y7L9).
    static let requirement = #"identifier "megacmd.mac" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "T9RH74Y7L9""#

    private let fileManager = FileManager.default
    private var resolved: URL?
    private var installing: Task<URL, Error>?

    /// Le MEGAcmd que Fil installe : `~/Library/Application Support/Fil/MEGAcmd.app`.
    static var privateApp: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fil", isDirectory: true)
            .appendingPathComponent("MEGAcmd.app", isDirectory: true)
    }

    /// Vrai si un MEGAcmd est déjà là : la page d'attente ne parle d'installation que sinon.
    nonisolated static var isInstalled: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications/MEGAcmd.app", home + "/Applications/MEGAcmd.app", privateApp.path]
            .contains { FileManager.default.isExecutableFile(atPath: $0 + "/Contents/MacOS/mega-exec") }
    }

    /// Dossier qui contient `mega-exec`. Un MEGAcmd déjà installé par l'utilisateur passe en premier.
    func directory() async throws -> URL {
        if let resolved, fileManager.isExecutableFile(atPath: resolved.appendingPathComponent("mega-exec").path) { return resolved }
        let home = fileManager.homeDirectoryForCurrentUser.path
        let apps = ["/Applications/MEGAcmd.app", home + "/Applications/MEGAcmd.app", Self.privateApp.path]
        if let found = apps.map({ URL(fileURLWithPath: $0 + "/Contents/MacOS", isDirectory: true) })
            .first(where: { fileManager.isExecutableFile(atPath: $0.appendingPathComponent("mega-exec").path) }) {
            resolved = found
            return found
        }
        if let installing { return try await installing.value }
        let task = Task { try await Self.install(into: Self.privateApp) }
        installing = task
        defer { installing = nil }
        let app = try await task.value
        resolved = app
        return app
    }

    /// Télécharge l'image disque officielle, la monte sans l'afficher, vérifie la signature, copie l'app, démonte.
    private static func install(into destination: URL) async throws -> URL {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("Fil-MEGAcmd-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        let image = work.appendingPathComponent("MEGAcmdSetup.dmg")
        do {
            let (downloaded, response) = try await URLSession.shared.download(from: downloadURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try fileManager.moveItem(at: downloaded, to: image)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderError.server("Fil n'a pas pu télécharger MEGAcmd, l'outil officiel de MEGA. Vérifie la connexion à Internet, puis réessaie.")
        }

        let mount = work.appendingPathComponent("volume", isDirectory: true)
        try fileManager.createDirectory(at: mount, withIntermediateDirectories: true)
        let environment = ProcessInfo.processInfo.environment
        let attach = await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, image.path], environment: environment, timeout: .seconds(120))
        guard attach.status == 0 else { throw ProviderError.server("Fil n'a pas pu ouvrir l'image de MEGAcmd téléchargée.") }
        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", "-force", mount.path]
            try? detach.run()
            detach.waitUntilExit()
        }

        let source = mount.appendingPathComponent("MEGAcmd.app", isDirectory: true)
        guard isGenuine(source) else {
            throw ProviderError.server("Le MEGAcmd téléchargé ne porte pas la signature de Mega Limited : Fil refuse de l'installer.")
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".MEGAcmd-\(UUID().uuidString).app", isDirectory: true)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        let copy = await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: [source.path, staging.path], environment: environment, timeout: .seconds(300))
        guard copy.status == 0, isGenuine(staging) else { throw ProviderError.server("Fil n'a pas pu installer MEGAcmd : \(copy.errorOutput)") }
        try fileManager.removeItemIfExists(at: destination)
        try fileManager.moveItem(at: staging, to: destination)
        return destination.appendingPathComponent("Contents/MacOS", isDirectory: true)
    }

    /// Signature valide, toutes architectures et code imbriqué compris, et signée par Mega Limited.
    nonisolated static func isGenuine(_ app: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement) == errSecSuccess else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}

#endif
