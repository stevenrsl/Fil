import Foundation
import UIKit

/// Les sessions d'arrière-plan des transferts WebDAV, vues depuis l'application.
///
/// Fil suspendu, iOS mène seul les GET et PUT en cours, puis réveille Fil pour lui rendre chaque
/// fichier terminé : la file enchaîne alors le suivant, ou annonce la fin. iOS confie à chaque réveil
/// un gestionnaire à rappeler une fois les nouvelles livrées ; ce registre le garde jusque-là.
///
/// Si Fil a été tué entre-temps, la file qui attendait ces fichiers n'existe plus : les sessions
/// laissées par la session précédente sont rouvertes au lancement, leurs tâches annulées, puis fermées.
/// Le registre de leurs identifiants est reconstructible : il ne sert qu'à ce ménage.
@MainActor
final class BackgroundSessions {
    static let shared = BackgroundSessions()

    private static let defaultsKey = "fil.backgroundSessions"
    private let defaults: UserDefaults
    /// Sessions tenues par un fournisseur vivant.
    private var live: Set<String> = []
    /// Sessions d'une vie antérieure de Fil, rouvertes seulement pour être soldées.
    private var orphans: [String: URLSession] = [:]
    /// Gestionnaires confiés par iOS, à rappeler quand la session a tout livré.
    private var waiting: [String: () -> Void] = [:]
    /// Appelé à chaque réveil : le temps de finir ce qui suit un fichier (renommage, fichier suivant).
    var onWake: (@MainActor () -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var recorded: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.defaultsKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Self.defaultsKey) }
    }

    func opened(_ identifier: String) {
        live.insert(identifier)
        recorded.insert(identifier)
    }

    func closed(_ identifier: String) {
        live.remove(identifier)
        recorded.remove(identifier)
        finishWaiting(identifier)
    }

    /// Au lancement : solde les sessions qu'aucun fournisseur de cette vie de Fil ne tient.
    func adoptLeftovers() {
        for identifier in recorded where !live.contains(identifier) {
            adopt(identifier)
        }
    }

    /// iOS a des nouvelles d'une session. Vivante, elle les reçoit d'elle-même ; sinon on la rouvre pour les solder.
    func handleEvents(for identifier: String, completion: @escaping () -> Void) {
        waiting[identifier] = completion
        onWake?()
        if !live.contains(identifier), orphans[identifier] == nil {
            adopt(identifier)
        }
    }

    func eventsFinished(_ identifier: String) {
        finishWaiting(identifier)
    }

    func orphanInvalidated(_ identifier: String) {
        orphans[identifier] = nil
        finishWaiting(identifier)
    }

    private func finishWaiting(_ identifier: String) {
        waiting.removeValue(forKey: identifier)?()
    }

    private func adopt(_ identifier: String) {
        guard identifier.hasPrefix(BackgroundTransferSession.identifierPrefix) else { return }
        let session = URLSession(
            configuration: BackgroundTransferSession.configuration(identifier: identifier),
            delegate: OrphanSessionDelegate(identifier: identifier),
            delegateQueue: nil
        )
        orphans[identifier] = session
        recorded.remove(identifier)
        Task {
            for task in await session.allTasks { task.cancel() }
            session.finishTasksAndInvalidate()
        }
    }
}

/// Ce que les fournisseurs WebDAV voient du registre : des appels depuis n'importe quel fil.
struct BackgroundSessionHooks: BackgroundSessionRegistry {
    func opened(_ identifier: String) {
        Task { @MainActor in BackgroundSessions.shared.opened(identifier) }
    }

    func closed(_ identifier: String) {
        Task { @MainActor in BackgroundSessions.shared.closed(identifier) }
    }

    func eventsFinished(_ identifier: String) {
        Task { @MainActor in BackgroundSessions.shared.eventsFinished(identifier) }
    }
}

/// Délégué d'une session orpheline : personne n'attend plus ses fichiers. Aucun identifiant n'est
/// fourni (défi refusé), un téléchargement arrivé est laissé à iOS, qui l'efface.
private final class OrphanSessionDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let identifier: String

    init(identifier: String) {
        self.identifier = identifier
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = identifier
        Task { @MainActor in BackgroundSessions.shared.eventsFinished(identifier) }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        let identifier = identifier
        Task { @MainActor in BackgroundSessions.shared.orphanInvalidated(identifier) }
    }
}

/// Le seul rôle du délégué d'application : recevoir les réveils d'iOS pour les sessions d'arrière-plan.
final class FilAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        BackgroundSessions.shared.handleEvents(for: identifier, completion: completionHandler)
    }
}

/// Fournisseurs de l'app iOS : WebDAV et kDrive transfèrent par une session d'arrière-plan.
enum MobileProviders {
    static func make(for connection: RemoteConnection, password: String) -> any RemoteFileProvider {
        switch connection.protocol {
        case .webdav, .kdrive:
            return WebDAVProvider(connection: connection, password: password, background: BackgroundSessionHooks())
        default:
            return ProviderFactory.make(for: connection, password: password)
        }
    }
}
