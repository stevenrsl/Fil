import UIKit
import UserNotifications

/// Autour de la file : un sursis quand Fil passe en arrière-plan, et une notification à la fin quand
/// Fil n'est pas devant. Les fichiers WebDAV, eux, passent par une session d'arrière-plan
/// (`BackgroundSessions`) et continuent sans ce sursis ; il sert aux requêtes courtes qui suivent
/// chaque fichier (renommage d'un envoi, fichier suivant d'un dossier).
@MainActor
final class MobileTransferActivity: TransferActivity {
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var isRunning = false
    private var askedForNotifications = false

    func began() {
        isRunning = true
        beginBackgroundTask()
        if !askedForNotifications {
            askedForNotifications = true
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// iOS rend la main à Fil pour lui livrer un fichier terminé : le temps d'enchaîner la suite.
    func wokeInBackground() {
        guard isRunning else { return }
        beginBackgroundTask()
    }

    func ended(_ outcome: TransferBatchOutcome?) {
        isRunning = false
        // Devant Fil, la barre des transferts suffit ; la notification est pour celui qui est parti ailleurs.
        guard let outcome, UIApplication.shared.applicationState != .active else {
            endBackgroundTask()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = outcome.title
        content.body = outcome.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        // Le sursis tient jusqu'à ce que la notification soit confiée au système.
        UNUserNotificationCenter.current().add(request) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isRunning else { return }
                self.endBackgroundTask()
            }
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        // Une trentaine de secondes, pas davantage : assez pour les requêtes courtes entre deux fichiers.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Transferts") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
