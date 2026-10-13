import Foundation

/// Un serveur configuré en FTP accepte-t-il aussi FTPS ?
///
/// La sonde est exigeante à dessein : elle ne conclut « disponible » que si la connexion chiffrée
/// s'ouvre, que le certificat est reconnu par macOS **et** qu'un listing du dossier de départ passe
/// (le canal de données chiffré est la partie qui casse le plus souvent). Proposer FTPS pour que
/// la connexion suivante échoue serait pire que de ne rien proposer.
enum FTPSProbe {
    enum Result: Equatable, Sendable {
        /// FTPS fonctionne : on peut proposer d'y passer.
        case available
        /// Le serveur propose TLS, mais son certificat n'est pas reconnu : passer en FTPS échouerait.
        case untrustedCertificate
        /// Pas de FTPS (ou pas de réponse à temps).
        case unavailable
    }

    /// Délai global : une sonde ne doit jamais traîner derrière un serveur muet.
    static let timeout: Duration = .seconds(20)

    static func check(_ connection: RemoteConnection, password: String, certificateAuthorities: String? = nil) async -> Result {
        // Le port 990 est du FTPS implicite : une connexion « FTP » dessus n'a pas de sens à sonder.
        guard connection.protocol == .ftp, connection.port != 990 else { return .unavailable }
        var secure = connection
        secure.protocol = .ftps
        let provider = FTPProvider(connection: secure, password: password, certificateAuthorities: certificateAuthorities)

        return await withTaskGroup(of: Result.self) { group in
            group.addTask {
                do {
                    let home = try await provider.connect()
                    _ = try await provider.list(home)
                    return .available
                } catch ProviderError.certificateUntrusted {
                    return .untrustedCertificate
                } catch {
                    return .unavailable
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .unavailable
            }
            let first = await group.next() ?? .unavailable
            group.cancelAll()
            return first
        }
    }
}
