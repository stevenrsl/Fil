import AppKit
import UserNotifications

/// Le Mac reste éveillé tant qu'un transfert tourne, et une notification dit la fin quand Fil
/// n'est pas devant : à 3 h du matin, on lance, on passe à autre chose, on est prévenu.
@MainActor
final class SystemTransferActivity: TransferActivity {
    private var token: NSObjectProtocol?
    private var askedForNotifications = false

    /// `UNUserNotificationCenter` exige un paquet .app : lancé par `swift run`, Fil s'en passe.
    private var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func began() {
        // Empêche la veille d'inactivité et le ralentissement d'App Nap, pas la mise en veille de l'écran.
        // Refermer un portable l'endort quand même : c'est un geste explicite.
        if token == nil {
            token = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Transferts en cours")
        }
        if canNotify, !askedForNotifications {
            askedForNotifications = true
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func ended(_ outcome: TransferBatchOutcome?) {
        if let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
        // Devant Fil, le plateau suffit ; la notification est pour celui qui est parti ailleurs.
        guard let outcome, canNotify, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = outcome.title
        content.body = outcome.body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
