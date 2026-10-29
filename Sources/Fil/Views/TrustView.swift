import SwiftUI

/// Phase « confirmer » : une première rencontre à vérifier avant de se connecter.
/// Deux cas, une seule page : l'empreinte d'un serveur SSH, ou un certificat que macOS ne reconnaît pas.
struct TrustView: View {
    let connection: RemoteConnection
    let request: TrustRequest
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        ScrollView {
            page
                .frame(maxWidth: Spacing.pageWidth, alignment: .leading)
                .padding(.horizontal, Spacing.page).padding(.top, Spacing.page).padding(.bottom, 64)
        }
    }

    /// Le contenu seul, sans défilement : c'est lui qu'on rend hors écran pour le contrôler.
    var page: some View {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: title, lede: connection.summary) {
                    PageTrail(text: request.isReplacement ? "Fil · Serveur différent" : "Fil · Première connexion")
                }
                Divider().overlay(Palette.hairline).padding(.top, 34)

                Text(explanation)
                    .font(TypeScale.body)
                    .foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.loose)

                VStack(alignment: .leading, spacing: Spacing.regular) {
                    switch request {
                    case .hostKey(let keys):
                        ForEach(keys) { key in
                            // Plusieurs clés : un rebond (ProxyJump) fait intervenir plusieurs serveurs. On dit lequel est lequel.
                            if keys.count > 1 { fact("Serveur", key.host) }
                            fact("Clé", key.typeLabel)
                            fingerprint([key.fingerprint], caption: "Empreinte")
                        }
                    case .certificate(let certificate):
                        fact("Nom", certificate.subject)
                        fact("Origine", certificate.isSelfSigned ? "Auto-signé : le serveur se présente lui-même" : "Signé par une autorité que macOS ne connaît pas")
                        if let expiry = certificate.notAfter {
                            fact("Expire", Format.date(expiry))
                        }
                        fingerprint(certificate.fingerprintLines, caption: "Empreinte SHA-256")
                    case .hostKeyReplacement(let previous, let presented):
                        if previous.isEmpty {
                            fact("Avant", "Introuvable : l'ancienne clé n'est pas dans un fichier que Fil sait relire")
                        }
                        ForEach(previous) { key in
                            fact("Avant", key.typeLabel)
                            fingerprint([key.fingerprint], caption: "Empreinte")
                        }
                        Divider().overlay(Palette.hairline)
                        ForEach(presented) { key in
                            fact("Maintenant", key.typeLabel)
                            fingerprint([key.fingerprint], caption: "Empreinte")
                        }
                    case .certificateReplacement(let previous, let presented):
                        fact("Avant", previous.subject)
                        fingerprint(previous.fingerprintLines, caption: "Empreinte SHA-256")
                        Divider().overlay(Palette.hairline)
                        fact("Maintenant", presented.subject)
                        if let expiry = presented.notAfter {
                            fact("Expire", Format.date(expiry))
                        }
                        fingerprint(presented.fingerprintLines, caption: "Empreinte SHA-256")
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

                HStack(spacing: Spacing.regular) {
                    Spacer()
                    if request.isReplacement {
                        // Remplacer une approbation est le geste risqué : Entrée annule, il faut cliquer pour remplacer.
                        Button("Remplacer l'approbation et se connecter", action: accept)
                            .buttonStyle(AccentButtonStyle())
                        Button("Annuler", action: decline)
                            .buttonStyle(QuietButtonStyle())
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Annuler", action: decline)
                            .buttonStyle(QuietButtonStyle())
                            .keyboardShortcut(.cancelAction)
                        Button("Faire confiance et se connecter", action: accept)
                            .buttonStyle(AccentButtonStyle())
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.top, Spacing.loose)
            }
    }

    private var title: String {
        switch request {
        case .hostKey: "Première connexion à « \(connection.resolvedHost) »"
        case .certificate: "Certificat à vérifier"
        case .hostKeyReplacement: "La clé de « \(connection.resolvedHost) » a changé"
        case .certificateReplacement: "Le certificat de « \(connection.resolvedHost) » a changé"
        }
    }

    private var explanation: String {
        switch request {
        case .hostKey:
            "Fil ne connaissait pas encore ce serveur. Son empreinte est sa signature : elle permet de s'assurer, aux connexions suivantes, qu'on parle bien au même serveur."
        case .certificate:
            "macOS ne reconnaît pas le certificat de ce serveur. C'est courant pour un NAS ou un serveur personnel, mais ce peut aussi être quelqu'un qui se fait passer pour lui."
        case .hostKeyReplacement:
            "Ce serveur ne présente plus la clé que tu avais approuvée. C'est normal après une réinstallation ou un changement de machine, mais ce peut aussi être quelqu'un qui se fait passer pour lui. Fil ne s'est pas connecté, et n'a envoyé aucun mot de passe."
        case .certificateReplacement:
            "Ce serveur ne présente plus le certificat que tu avais approuvé. C'est normal à un renouvellement, mais ce peut aussi être quelqu'un qui se fait passer pour lui. Fil ne s'est pas connecté, et n'a envoyé aucun mot de passe."
        }
    }

    private var advice: String {
        switch request {
        case .hostKey:
            "Compare cette empreinte avec celle que ton hébergeur ou ton administrateur t'a donnée. Fil la retient : si elle change un jour, il refusera de se connecter."
        case .certificate:
            "Compare cette empreinte avec celle qu'affiche ton serveur. Fil ne se connectera ensuite qu'à ce certificat précis, et refusera tout autre."
        case .hostKeyReplacement(let previous, _):
            previous.isEmpty
                ? "Demande la nouvelle empreinte à ton administrateur avant de remplacer. Fil retire l'ancienne approbation de son propre fichier et ne touche pas à ton known_hosts."
                : "Demande à ton administrateur si le serveur a été réinstallé, et compare la nouvelle empreinte avec la sienne. Fil retire l'ancienne approbation de son propre fichier et ne touche pas à ton known_hosts."
        case .certificateReplacement:
            "Compare la nouvelle empreinte avec celle qu'affiche ton serveur après son renouvellement. Si tu n'as rien changé, annule."
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Text(label)
                .font(TypeScale.label)
                .foregroundStyle(Palette.inkSoft)
                .frame(width: 130, alignment: .trailing)
            Text(value)
                .font(TypeScale.body)
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
        }
    }

    private func fingerprint(_ lines: [String], caption: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Text(caption)
                .font(TypeScale.label)
                .foregroundStyle(Palette.inkSoft)
                .frame(width: 130, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                }
            }
            .textSelection(.enabled)
        }
    }
}
