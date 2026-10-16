import Foundation

/// Ce que dit la notification quand la file se vide : un titre et une phrase.
public struct TransferBatchOutcome: Equatable, Sendable {
    public var title: String
    public var body: String
    public var hasFailures: Bool

    /// `nil` quand il n'y a rien à dire : tout a été annulé à la main, ou rien n'a tourné.
    public static func of(_ items: [TransferItem]) -> TransferBatchOutcome? {
        let done = items.filter { $0.state == .done }
        let failed = items.filter { if case .failed = $0.state { true } else { false } }
        guard !done.isEmpty || !failed.isEmpty else { return nil }

        if failed.isEmpty {
            if done.count == 1 {
                let item = done[0]
                let verb = item.direction == .download ? "téléchargé" : "envoyé"
                return TransferBatchOutcome(title: "« \(item.name) » \(verb)", body: item.phrase(now: .now), hasFailures: false)
            }
            let bytes = done.compactMap(\.totalBytes).reduce(0, +)
            let size = bytes > 0 ? " · \(Format.bytes(bytes))" : ""
            return TransferBatchOutcome(title: "Transferts terminés", body: "\(Format.plural(done.count, "transfert réussi", "transferts réussis"))\(size)", hasFailures: false)
        }

        let title = failed.count == 1 ? "Un transfert a échoué" : "\(Format.count(failed.count)) transferts ont échoué"
        let body: String
        if failed.count == 1, case .failed(let reason) = failed[0].state {
            let others = switch done.count {
            case 0: ""
            case 1: " L'autre est arrivé."
            default: " Les \(Format.count(done.count)) autres sont arrivés."
            }
            body = "« \(failed[0].name) » : \(reason)\(others)"
        } else {
            let arrived = done.isEmpty ? "Aucun n'est arrivé." : "\(Format.plural(done.count, "autre est arrivé", "autres sont arrivés"))."
            body = "\(arrived) Le plateau des transferts dit pourquoi."
        }
        return TransferBatchOutcome(title: title, body: body, hasFailures: true)
    }
}
