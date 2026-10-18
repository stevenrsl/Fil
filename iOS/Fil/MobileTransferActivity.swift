import UIKit
import UserNotifications

/// Pendant un transfert, l'écran ne s'éteint pas, et iOS accorde un court sursis si Fil passe en
/// arrière-plan. Une notification dit la fin quand Fil n'est pas devant.
@MainActor
final class MobileTransferActivity: TransferActivity {
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var isRunning = false
    private var askedForNotifications = false

    func began() {
        isRunning = true
        // À 3 h du matin, le téléphone posé à côté : l'écran reste allumé tant que ça tourne.
        UIApplication.shared.isIdleTimerDisabled = true
        if backgroundTask == .invalid {
            // Quelques dizaines de secondes, pas davantage : iOS suspend ensuite Fil, et les transferts avec.
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Transferts") { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundTask() }
            }
        }
        if !askedForNotifications {
            askedForNotifications = true
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func ended(_ outcome: TransferBatchOutcome?) {
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
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

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
