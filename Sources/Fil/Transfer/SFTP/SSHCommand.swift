import Foundation

/// Lancement d'OpenSSH pour SFTP : arguments, environnement, lecture des échecs.
enum SSHCommand {
    static let executable = URL(fileURLWithPath: "/usr/bin/ssh")

    /// Les options en ligne de commande priment sur `~/.ssh/config`, qui reste lu pour le reste
    /// (alias d'hôte, clés, `ProxyJump`…). Le port 22 n'est pas imposé pour laisser un alias choisir le sien.
    static func arguments(for connection: RemoteConnection, extraOptions: [String] = []) -> [String] {
        var arguments = [
            "-T", "-x", "-a", "-e", "none",
            "-o", "ClearAllForwardings=yes",
            "-o", "PermitLocalCommand=no",
            "-o", "BatchMode=no",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            // Première connexion : l'empreinte est mémorisée. Empreinte changée : refus.
            "-o", "StrictHostKeyChecking=accept-new",
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
        arguments += ["-s", "--", connection.resolvedHost, "sftp"]
        return arguments
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
        if text.contains("remote host identification has changed") || text.contains("host key verification failed") {
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
            .last { !$0.isEmpty && !$0.lowercased().hasPrefix("warning:") }
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
