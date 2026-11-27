import SwiftUI

/// Le seul bouton plein d'un écran.
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TypeScale.button)
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 18).frame(minHeight: Spacing.control)
            .background(Palette.accent, in: Capsule())
            // Au survol, un filet d'encre d'accent : le bouton répond sans changer de couleur.
            .overlay(Capsule().strokeBorder(Palette.accentInk.opacity(isHovered && isEnabled ? 0.35 : 0), lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
    }
}

/// Action secondaire : un lien, rien de plus.
struct QuietButtonStyle: ButtonStyle {
    var tint: Color = Palette.accentInk
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TypeScale.label)
            .foregroundStyle(tint)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

/// Outil discret de barre : icône et libellé, fond au survol.
struct ToolButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TypeScale.label)
            .foregroundStyle(Palette.inkSoft)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(isHovered && isEnabled ? Palette.groundSunk : .clear, in: RoundedRectangle(cornerRadius: Radius.small))
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
            .onHover { isHovered = $0 }
    }
}

struct PageTrail: View {
    let text: String
    var body: some View { Text(text).font(TypeScale.label).foregroundStyle(Palette.inkSoft) }
}

/// Fil d'Ariane, titre serif et chapeau : l'entête de chaque page.
struct PageHeader<Trail: View>: View {
    let title: String
    var lede: String?
    @ViewBuilder var trail: Trail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            trail
            Text(title)
                .font(TypeScale.display)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, Spacing.tight)
            if let lede {
                Text(lede)
                    .font(TypeScale.lede)
                    .foregroundStyle(Palette.inkSoft)
                    .padding(.top, 6)
            }
        }
    }
}

/// Une attente dit toujours ce qu'elle attend.
struct WaitingLine: View {
    let text: String

    var body: some View {
        HStack(spacing: Spacing.tight) {
            ProgressView().controlSize(.small)
            Text(text).font(TypeScale.label).foregroundStyle(Palette.inkSoft)
        }
    }
}

/// Condition bloquante, en clair.
struct ReasonLine: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(TypeScale.label)
            .foregroundStyle(Palette.inkSoft)
    }
}

struct AlertBanner: View {
    let text: String
    var action: (label: String, perform: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
            Image(systemName: "exclamationmark.triangle")
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.tight)
            if let action {
                Button(action.label, action: action.perform).buttonStyle(QuietButtonStyle(tint: Palette.alert)).underline()
            }
        }
        .font(TypeScale.label)
        .foregroundStyle(Palette.alert)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Palette.alertWash, in: RoundedRectangle(cornerRadius: Radius.medium))
    }
}

/// Une proposition, pas une erreur : fond d'accent doux, deux liens, aucun bouton plein.
struct OfferBanner: View {
    let text: String
    let accept: (label: String, perform: () -> Void)
    let dismiss: (label: String, perform: () -> Void)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Image(systemName: "lock")
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.tight)
            Button(accept.label, action: accept.perform)
                .buttonStyle(QuietButtonStyle()).underline()
            Button(dismiss.label, action: dismiss.perform)
                .buttonStyle(QuietButtonStyle(tint: Palette.inkSoft))
        }
        .font(TypeScale.label)
        .foregroundStyle(Palette.accentInk)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Palette.accentWash, in: RoundedRectangle(cornerRadius: Radius.medium))
    }
}

struct ThinProgress: View {
    /// `nil` : durée inconnue, la barre respire au lieu d'avancer.
    let fraction: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline)
                if let fraction {
                    Capsule().fill(Palette.progress).frame(width: max(3, geometry.size.width * fraction))
                } else {
                    // Trente images par seconde suffisent à une barre qui respire en 1,6 s.
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        Capsule().fill(Palette.progress.opacity(0.6))
                            .frame(width: geometry.size.width * 0.25)
                            .offset(x: geometry.size.width * (phase * 1.25 - 0.25))
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: 3)
    }
}

/// Champ de saisie sur fond de surface, filet fin.
struct FieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(TypeScale.body)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Radius.small).stroke(Palette.hairline))
    }
}

/// Pastille d'un protocole dans la barre latérale.
struct ProtocolBadge: View {
    let proto: RemoteProtocol
    var isActive = false

    var body: some View {
        Text(String(proto.label.prefix(1)))
            .font(TypeScale.badge)
            // Inactive, la lettre est à l'encre d'accent : `onAccent` sur `accentWash` ne se lit pas en sombre.
            .foregroundStyle(isActive ? Palette.onAccent : Palette.accentInk)
            .frame(width: 20, height: 20)
            .background(isActive ? Palette.accent : Palette.accentWash, in: RoundedRectangle(cornerRadius: Radius.small))
    }
}

/// Choix du mode graphique : une vignette par mode, dans ses propres couleurs. Le choix s'applique tout de suite.
struct ThemePicker: View {
    @Binding var selection: ThemeID

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 84), spacing: Spacing.regular, alignment: .topLeading)], alignment: .leading, spacing: Spacing.regular) {
            ForEach(ThemeID.allCases, id: \.self) { theme in
                Button { selection = theme } label: { swatch(theme) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mode \(theme.label)")
                    .accessibilityHint(theme.summary)
                    .accessibilityAddTraits(theme == selection ? .isSelected : [])
            }
        }
    }

    private func swatch(_ theme: ThemeID) -> some View {
        let isSelected = theme == selection
        return VStack(alignment: .leading, spacing: Spacing.tight) {
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(Palette.preview(\.ink, of: theme)).frame(width: 40, height: 4)
                Capsule().fill(Palette.preview(\.inkFaint, of: theme)).frame(width: 28, height: 4)
                Spacer(minLength: 0)
                Capsule().fill(Palette.preview(\.accent, of: theme)).frame(width: 34, height: 10)
            }
            .padding(9)
            .frame(width: 84, height: 56, alignment: .topLeading)
            .background(Palette.preview(\.ground, of: theme), in: RoundedRectangle(cornerRadius: Radius.small))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.small)
                    .strokeBorder(isSelected ? Palette.accentInk : Palette.hairline, lineWidth: isSelected ? 2 : 1)
            )
            Text(theme.label)
                .font(TypeScale.label)
                .foregroundStyle(isSelected ? Palette.ink : Palette.inkSoft)
        }
        .contentShape(Rectangle())
    }
}
