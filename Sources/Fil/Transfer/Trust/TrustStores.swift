import CryptoKit
import Foundation
import Security

/// Dossier où Fil range ce qu'il retient : `~/Library/Application Support/Fil`.
/// Rien n'est écrit dans `~/.ssh` : ce que l'utilisateur approuve dans Fil reste dans Fil, et se retire d'un geste.
enum FilSupportFolder {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Fil", isDirectory: true)
    }

    /// Crée le dossier (lisible par l'utilisateur seul) s'il manque.
    static func ensure(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

/// Clés de serveurs SSH approuvées dans Fil. `ssh` les lit comme un fichier `known_hosts` supplémentaire
/// (`GlobalKnownHostsFile`), en plus de celui de l'utilisateur, qui reste intact.
struct FilKnownHosts: Sendable {
    let url: URL

    static let standard = FilKnownHosts(url: FilSupportFolder.url.appendingPathComponent("known_hosts"))

    /// Ajoute les clés qui n'y sont pas déjà. Le fichier n'est lisible que par l'utilisateur.
    func trust(_ keys: [HostKey]) throws {
        do {
            try FilSupportFolder.ensure(url.deletingLastPathComponent())
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let known = Set(existing.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
            let added = keys.map(\.line).filter { !known.contains($0) }
            guard !added.isEmpty else { return }
            var text = existing
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            text += added.joined(separator: "\n") + "\n"
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw ProviderError.server("Impossible d'enregistrer l'empreinte du serveur : \(error.localizedDescription)")
        }
    }

    /// Remplace l'approbation d'un serveur dont la clé a changé : les lignes de Fil pour le même hôte et
    /// le même type de clé partent, les nouvelles arrivent. Le `known_hosts` de l'utilisateur n'est jamais touché.
    func replace(with keys: [HostKey]) throws {
        do {
            try FilSupportFolder.ensure(url.deletingLastPathComponent())
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let replaced = Set(keys.map { "\($0.host) \($0.type)" })
            let kept = existing.split(whereSeparator: \.isNewline).filter { raw in
                let fields = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
                return !(fields.count >= 2 && replaced.contains("\(fields[0]) \(fields[1])"))
            }
            let text = (kept.map(String.init) + keys.map(\.line)).joined(separator: "\n") + "\n"
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw ProviderError.server("Impossible d'enregistrer l'empreinte du serveur : \(error.localizedDescription)")
        }
    }

    /// Les anciennes clés des serveurs que `presented` désigne, d'après le fichier de Fil puis ceux de `ssh`.
    /// Un hôte condensé (`|1|…`) se reconnaît en recalculant son condensé : on ne le lit jamais à l'envers.
    func previousKeys(for presented: [HostKey], also files: [URL] = FilKnownHosts.systemFiles) -> [HostKey] {
        var found: [HostKey] = []
        for file in [url] + files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for raw in text.split(whereSeparator: \.isNewline) {
                guard let key = HostKey(knownHostsLine: String(raw)) else { continue }
                let matches = presented.contains { Self.hostField(key.host, names: $0.host) }
                if matches, !presented.contains(where: { $0.fingerprint == key.fingerprint }), !found.contains(where: { $0.fingerprint == key.fingerprint }) {
                    found.append(key)
                }
            }
        }
        return found
    }

    /// Le `known_hosts` de l'utilisateur et ceux du système : là où vit souvent l'ancienne clé.
    static var systemFiles: [URL] {
        [URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/known_hosts"),
         URL(fileURLWithPath: "/etc/ssh/ssh_known_hosts")]
    }

    /// Vrai si le champ « hôtes » d'une ligne `known_hosts` désigne `name` : liste séparée par des virgules, ou condensé.
    static func hostField(_ field: String, names name: String) -> Bool {
        if field.hasPrefix("|1|") {
            let parts = field.split(separator: "|", omittingEmptySubsequences: true)
            guard parts.count == 3, let salt = Data(base64Encoded: String(parts[1])), let hash = Data(base64Encoded: String(parts[2])) else { return false }
            let code = HMAC<Insecure.SHA1>.authenticationCode(for: Data(name.utf8), using: SymmetricKey(data: salt))
            return Data(code) == hash
        }
        return field.split(separator: ",").contains { $0 == name }
    }
}

/// Certificats approuvés, un fichier PEM par empreinte. libcurl s'en sert comme seule autorité reconnue :
/// le certificat approuvé est accepté, tout autre est refusé.
struct PinnedCertificates: Sendable {
    let folder: URL

    static let standard = PinnedCertificates(folder: FilSupportFolder.url.appendingPathComponent("certificates", isDirectory: true))

    func pemURL(for sha256: String) -> URL? {
        let url = folder.appendingPathComponent("\(sha256).pem")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func save(_ certificate: CertificateInfo) throws {
        do {
            try FilSupportFolder.ensure(folder)
            let body = certificate.der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            let pem = "-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----\n"
            let url = folder.appendingPathComponent("\(certificate.sha256).pem")
            try pem.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ProviderError.server("Impossible d'enregistrer le certificat : \(error.localizedDescription)")
        }
    }

    func remove(_ sha256: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(sha256).pem"))
    }
}

extension CertificateInfo {
    /// Lit un certificat DER : nom, auto-signé ou non, date d'expiration.
    init?(der: Data) {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        let subject = (SecCertificateCopySubjectSummary(certificate) as String?) ?? "Certificat sans nom"
        let subjectSequence = SecCertificateCopyNormalizedSubjectSequence(certificate) as Data?
        let issuerSequence = SecCertificateCopyNormalizedIssuerSequence(certificate) as Data?
        var expiry: Date?
        #if os(macOS)
        // iOS ne publie pas `SecCertificateCopyValues` : la date d'expiration n'y est pas montrée.
        var error: Unmanaged<CFError>?
        if let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1ValidityNotAfter] as CFArray, &error) as? [String: Any],
           let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
           let seconds = entry["value"] as? Double {
            expiry = Date(timeIntervalSinceReferenceDate: seconds)
        }
        #endif
        self.init(
            sha256: CertificateInfo.sha256Hex(of: der),
            subject: subject,
            isSelfSigned: subjectSequence != nil && subjectSequence == issuerSequence,
            notAfter: expiry,
            der: der
        )
    }
}
