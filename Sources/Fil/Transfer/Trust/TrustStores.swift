import Foundation
import Security

/// Dossier où Fil range ce qu'il retient : `~/Library/Application Support/Fil`.
/// Rien n'est écrit dans `~/.ssh` : ce que l'utilisateur approuve dans Fil reste dans Fil, et se retire d'un geste.
enum FilSupportFolder {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
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
        var error: Unmanaged<CFError>?
        if let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1ValidityNotAfter] as CFArray, &error) as? [String: Any],
           let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
           let seconds = entry["value"] as? Double {
            expiry = Date(timeIntervalSinceReferenceDate: seconds)
        }
        self.init(
            sha256: CertificateInfo.sha256Hex(of: der),
            subject: subject,
            isSelfSigned: subjectSequence != nil && subjectSequence == issuerSequence,
            notAfter: expiry,
            der: der
        )
    }
}
