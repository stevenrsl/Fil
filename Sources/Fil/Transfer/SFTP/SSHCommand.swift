import Foundation

/// Lancement d'OpenSSH pour SFTP : arguments, environnement, lecture des échecs.
enum SSHCommand {
    static let executable = URL(fileURLWithPath: "/usr/bin/ssh")

    /// Les options en ligne de commande priment sur `~/.ssh/config`, qui reste lu pour le reste
    /// (alias d'hôte, clés, `ProxyJump`…). Le port 22 n'est pas imposé pour laisser un alias choisir le sien.
    ///
    /// Vérification **stricte** de la clé du serveur : un serveur inconnu n'est jamais accepté en silence.
    /// Il faut d'abord que l'utilisateur ait vérifié son empreinte (`HostKeyDiscovery`), après quoi la clé
    /// vit dans le fichier de Fil, que `ssh` lit en plus de `known_hosts` sans jamais y écrire.
    static func arguments(for connection: RemoteConnection, extraOptions: [String] = [], trustedHosts: URL? = FilKnownHosts.standard.url) -> [String] {
        var arguments = ["-T", "-x", "-a", "-e", "none", "-o", "StrictHostKeyChecking=yes", "-o", "UpdateHostKeys=no"]
        if let option = globalKnownHostsOption(trustedHosts) { arguments += ["-o", option] }
        arguments += ["-o", "BatchMode=no"]
        arguments += connectionOptions(for: connection, extraOptions: extraOptions)
        arguments += ["-s", "--", connection.resolvedHost, "sftp"]
        return arguments
    }

    /// Connexion d'essai pour relever la clé d'un serveur inconnu. Ses options passent avant toutes les autres
    /// (`ssh` garde la première valeur d'une option) : rien n'est lu ni écrit hors du fichier jetable,
    /// et aucun identifiant n'est envoyé (`PreferredAuthentications=none`).
    static func discoveryArguments(for connection: RemoteConnection, extraOptions: [String] = [], knownHostsFile: URL) -> [String] {
        var arguments = [
            "-T", "-x", "-a", "-e", "none",
            "-o", "UserKnownHostsFile=\(knownHostsFile.path)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UpdateHostKeys=no",
            "-o", "PreferredAuthentications=none",
            "-o", "BatchMode=yes"
        ]
        arguments += connectionOptions(for: connection, extraOptions: extraOptions)
        arguments += ["--", connection.resolvedHost, "true"]
        return arguments
    }

    private static func connectionOptions(for connection: RemoteConnection, extraOptions: [String]) -> [String] {
        var arguments = [
            "-o", "ClearAllForwardings=yes",
            "-o", "PermitLocalCommand=no",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "NumberOfPasswordPrompts=1"
        ]
        arguments += extraOptions
        if connection.port != RemoteProtocol.sftp.defaultPort {
            arguments += ["-p", String(connection.port)]
        }
        let user = connection.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty {
            arguments += ["-l", user]
        }
        return arguments
    }

    /// Les fichiers du système, plus celui de Fil. Un chemin avec des guillemets ne peut pas être cité : il est ignoré.
    private static func globalKnownHostsOption(_ trustedHosts: URL?) -> String? {
        guard let path = trustedHosts?.path, !path.contains("\""), !path.contains("\\") else { return nil }
        return "GlobalKnownHostsFile=\"/etc/ssh/ssh_known_hosts\" \"/etc/ssh/ssh_known_hosts2\" \"\(path)\""
    }

    /// Le mot de passe ne passe ni par les arguments ni par l'environnement : `ssh` le demande
    /// à Fil lui-même (`SSH_ASKPASS`), qui le relit dans le Keychain d'après l'identifiant de connexion.
    static func environment(base: [String: String], askpass: String, connectionID: UUID) -> [String: String] {
        var environment = base
        environment["SSH_ASKPASS"] = askpass
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
        environment[Askpass.connectionVariable] = connectionID.uuidString
        return environment
    }

    /// Traduit la sortie d'erreur d'un `ssh` terminé en raison lisible.
    static func describeExit(status: Int32, errorOutput: String, host: String, port: Int) -> ProviderError {
        let text = errorOutput.lowercased()
        if text.contains("remote host identification has changed") {
            return .hostKeyChanged(host)
        }
        // « No ED25519 host key is known for … and you have requested strict checking » : serveur jamais vu.
        if text.contains("host key is known for") {
            return .hostKeyUnknown([])
        }
        if text.contains("host key verification failed") {
            return .hostKeyChanged(host)
        }
        if text.contains("could not resolve hostname") || text.contains("nodename nor servname") {
            return .hostNotFound(host)
        }
        if text.contains("connection refused") {
            return .connectionRefused(host: host, port: port)
        }
        if text.contains("timed out") {
            return .timedOut
        }
        if text.contains("no route to host") || text.contains("network is unreachable") {
            return .server("« \(host) » est injoignable depuis ce réseau.")
        }
        if text.contains("permission denied") || text.contains("too many authentication failures") {
            return .server("Le serveur refuse l'identifiant, le mot de passe ou la clé SSH.")
        }
        if text.contains("subsystem request failed") {
            return .server("Le serveur n'accepte pas SFTP pour ce compte.")
        }
        if text.contains("connection closed") || text.contains("connection reset") || text.contains("broken pipe") {
            return .connectionLost
        }
        let meaningful = errorOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.lowercased().hasPrefix("warning:") && !$0.lowercased().hasPrefix("debug") }
        if let meaningful {
            return .server("La connexion SSH a échoué : \(meaningful)")
        }
        return .connectionLost
    }
}

/// Fil joue aussi le rôle d'assistant `SSH_ASKPASS` : même binaire, lancé par `ssh` avec la question en argument.
enum Askpass {
    static let connectionVariable = "FIL_ASKPASS_CONNECTION"

    static var helperPath: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    /// Code de sortie quand le processus a été lancé comme assistant, `nil` sinon.
    static func runIfRequested(environment: [String: String], arguments: [String], secrets: any SecretStore) -> Int32? {
        guard let raw = environment[connectionVariable], let id = UUID(uuidString: raw) else { return nil }
        let prompt = arguments.dropFirst().first ?? ""
        guard isSecretPrompt(prompt), let password = secrets.password(for: id), !password.isEmpty else {
            // Toute autre question (confirmation, code à usage unique) est refusée : ssh abandonne proprement.
            return 1
        }
        FileHandle.standardOutput.write(Data((password + "\n").utf8))
        return 0
    }

    static func isSecretPrompt(_ prompt: String) -> Bool {
        let prompt = prompt.lowercased()
        return prompt.contains("password") || prompt.contains("passphrase") || prompt.contains("mot de passe")
    }
}
