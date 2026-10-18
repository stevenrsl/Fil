import SwiftUI

/// Phase « confirmer » : une première rencontre à vérifier avant de se connecter. Sur iOS, c'est un
/// certificat que le système ne reconnaît pas (NAS, serveur personnel).
struct TrustPage: View {
    let connection: RemoteConnection
    let request: TrustRequest
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: title, lede: connection.summary) {
                    PageTrail(text: "Fil · Première connexion")
                }
                Divider().overlay(Palette.hairline).padding(.top, Spacing.loose)

                Text(explanation)
                    .font(TypeScale.body)
                    .foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.loose)

                VStack(alignment: .leading, spacing: Spacing.regular) {
                    switch request {
                    case .hostKey(let keys):
                        ForEach(keys) { key in
                            if keys.count > 1 { fact("Serveur", key.host) }
                            fact("Clé", key.typeLabel)
                            fingerprint([key.fingerprint], caption: "Empreinte")
                        }
                    case .certificate(let certificate):
                        fact("Nom", certificate.subject)
                        fact("Origine", certificate.isSelfSigned ? "Auto-signé : le serveur se présente lui-même" : "Signé par une autorité que \(Platform.system) ne connaît pas")
                        if let expiry = certificate.notAfter {
                            fact("Expire", Format.date(expiry))
                        }
                        fingerprint(certificate.fingerprintLines, caption: "Empreinte SHA-256")
                    }
                }
                .padding(Spacing.regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.medium))
                .overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(Palette.hairline))
                .padding(.top, Spacing.loose)

                Text(advice)
                    .font(TypeScale.label)
                    .foregroundStyle(Palette.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.regular)
            }
            .padding(Spacing.page)
        }
        .background(Palette.ground)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: Spacing.regular) {
                Button(action: accept) {
                    Text("Faire confiance et se connecter").frame(maxWidth: .infinity)
                }
                .buttonStyle(AccentButtonStyle())
                Button("Annuler", action: decline)
                    .buttonStyle(QuietButtonStyle())
            }
            .padding(.horizontal, Spacing.page).padding(.vertical, Spacing.regular)
            .background(Palette.ground)
        }
    }

    private var title: String {
        switch request {
        case .hostKey: "Première connexion à « \(connection.resolvedHost) »"
        case .certificate: "Certificat à vérifier"
        }
    }

    private var explanation: String {
        switch request {
        case .hostKey:
            "Fil ne connaissait pas encore ce serveur. Son empreinte est sa signature : elle permet de s'assurer, aux connexions suivantes, qu'on parle bien au même serveur."
        case .certificate:
            "\(Platform.system) ne reconnaît pas le certificat de ce serveur. C'est courant pour un NAS ou un serveur personnel, mais ce peut aussi être quelqu'un qui se fait passer pour lui."
        }
    }

    private var advice: String {
        switch request {
        case .hostKey:
            "Compare cette empreinte avec celle que ton hébergeur ou ton administrateur t'a donnée. Fil la retient : si elle change un jour, il refusera de se connecter."
        case .certificate:
            "Compare cette empreinte avec celle qu'affiche ton serveur. Fil ne se connectera ensuite qu'à ce certificat précis, et refusera tout autre."
        }
    }

    /// Étiquette au-dessus de la valeur : l'écran d'un téléphone n'a pas la place de les mettre côte à côte.
    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(TypeScale.caption)
                .foregroundStyle(Palette.inkSoft)
            Text(value)
                .font(TypeScale.body)
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
        }
    }

    private func fingerprint(_ lines: [String], caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(TypeScale.caption)
                .foregroundStyle(Palette.inkSoft)
            // Huit octets par ligne : une ligne de seize ne tient pas en largeur sur un téléphone.
            ForEach(lines.flatMap(Self.halves), id: \.self) { line in
                Text(line)
                    .font(TypeScale.figures)
                    .foregroundStyle(Palette.ink)
            }
            .textSelection(.enabled)
        }
    }

    private static func halves(_ line: String) -> [String] {
        let octets = line.split(separator: ":")
        guard octets.count > 8 else { return [line] }
        return [octets.prefix(8).joined(separator: ":"), octets.dropFirst(8).joined(separator: ":")]
    }
}
