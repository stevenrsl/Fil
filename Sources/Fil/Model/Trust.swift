import CryptoKit
import Foundation

/// Clé d'un serveur SSH, telle qu'elle sera enregistrée et telle qu'on la montre à l'utilisateur.
public struct HostKey: Equatable, Hashable, Sendable, Identifiable {
    /// Champ « hôtes » de la ligne `known_hosts` : un nom, `[nom]:port`, ou un condensé `|1|…`.
    public let host: String
    /// `ssh-ed25519`, `ecdsa-sha2-nistp256`, `ssh-rsa`…
    public let type: String
    /// `SHA256:` suivi du condensé en base 64 sans remplissage : le format que montrent `ssh` et `ssh-keygen`.
    public let fingerprint: String
    /// La ligne `known_hosts` complète, sans retour à la ligne.
    public let line: String

    public var id: String { host + " " + fingerprint }

    public var typeLabel: String {
        switch type {
        case "ssh-ed25519": "ED25519"
        case "ssh-rsa": "RSA"
        case "ssh-dss": "DSA"
        case let other where other.hasPrefix("ecdsa-sha2-"): "ECDSA"
        case let other where other.hasPrefix("sk-"): "clé de sécurité"
        default: type
        }
    }

    public init(host: String, type: String, fingerprint: String, line: String) {
        self.host = host
        self.type = type
        self.fingerprint = fingerprint
        self.line = line
    }

    /// Lit une ligne `known_hosts`. Les commentaires, les lignes vides et les marqueurs
    /// (`@cert-authority`, `@revoked`) ne sont pas des clés à approuver : `nil`.
    public init?(knownHostsLine raw: String) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("@") else { return nil }
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 3, let fingerprint = Self.fingerprint(ofBase64: String(fields[2])) else { return nil }
        self.init(host: String(fields[0]), type: String(fields[1]), fingerprint: fingerprint, line: fields.prefix(3).joined(separator: " "))
    }

    static func fingerprint(ofBase64 blob: String) -> String? {
        guard let data = Data(base64Encoded: blob), !data.isEmpty else { return nil }
        let digest = Data(SHA256.hash(data: data)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }
}

/// Certificat TLS présenté par un serveur, assez décrit pour que l'utilisateur le reconnaisse.
public struct CertificateInfo: Equatable, Sendable {
    /// Condensé SHA-256 du certificat entier, en hexadécimal minuscule (64 caractères).
    public let sha256: String
    public let subject: String
    public let isSelfSigned: Bool
    public let notAfter: Date?
    /// Le certificat tel qu'envoyé (DER) : c'est lui qu'on enregistre pour l'épingler.
    public let der: Data

    public init(sha256: String, subject: String, isSelfSigned: Bool, notAfter: Date?, der: Data) {
        self.sha256 = sha256
        self.subject = subject
        self.isSelfSigned = isSelfSigned
        self.notAfter = notAfter
        self.der = der
    }

    public static func sha256Hex(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// `A0:FA:08:4E:…` : le format qu'affichent les serveurs et les navigateurs.
    public var fingerprint: String { Self.grouped(sha256) }

    /// L'empreinte sur plusieurs lignes de 16 octets, coupées entre deux octets : elle se compare à l'œil sans bégayer.
    public var fingerprintLines: [String] { Self.lines(of: fingerprint) }

    static func lines(of fingerprint: String) -> [String] {
        let octets = fingerprint.split(separator: ":")
        return stride(from: 0, to: octets.count, by: 16).map { octets[$0..<min($0 + 16, octets.count)].joined(separator: ":") }
    }

    public static func grouped(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 2).map { offset -> String in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<hex.index(start, offsetBy: min(2, hex.count - offset))]).uppercased()
        }.joined(separator: ":")
    }
}

/// Ce qu'on retient d'un certificat approuvé : de quoi le reconnaître et l'afficher, rien de secret.
public struct TrustedCertificate: Codable, Equatable, Hashable, Sendable {
    public let sha256: String
    public let subject: String

    public init(sha256: String, subject: String) {
        self.sha256 = sha256
        self.subject = subject
    }

    public var fingerprint: String { CertificateInfo.grouped(sha256) }
    public var fingerprintLines: [String] { CertificateInfo.lines(of: fingerprint) }
}

/// Ce que Fil demande à l'utilisateur de vérifier avant de se connecter.
public enum TrustRequest: Equatable, Sendable {
    /// Première rencontre avec un serveur SSH.
    case hostKey([HostKey])
    /// Première rencontre avec un certificat que le système ne reconnaît pas.
    case certificate(CertificateInfo)
    /// Un serveur SSH approuvé présente une autre clé. `previous` peut être vide : l'ancienne clé
    /// vivait dans un fichier que Fil ne sait pas relire (empreinte condensée par un autre outil).
    case hostKeyReplacement(previous: [HostKey], presented: [HostKey])
    /// Un certificat approuvé n'est plus celui que présente le serveur.
    case certificateReplacement(previous: TrustedCertificate, presented: CertificateInfo)

    /// Vrai quand l'utilisateur avait déjà approuvé ce serveur : l'écran doit alors peser le risque,
    /// pas souhaiter la bienvenue.
    public var isReplacement: Bool {
        switch self {
        case .hostKey, .certificate: false
        case .hostKeyReplacement, .certificateReplacement: true
        }
    }
}
