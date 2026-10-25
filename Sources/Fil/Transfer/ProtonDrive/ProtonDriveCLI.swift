import CryptoKit
import Foundation

#if os(macOS)

/// Installe le binaire officiel Proton Drive sans dépendre d'un outil présent dans le PATH.
actor ProtonDriveCLI {
    static let version = "0.9.0"
    private let fileManager = FileManager.default
    private var executable: URL?

    private var directory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fil", isDirectory: true)
            .appendingPathComponent("ProtonDrive", isDirectory: true)
    }

    func executableURL() async throws -> URL {
        if let executable, fileManager.isExecutableFile(atPath: executable.path) { return executable }
        let installed = directory.appendingPathComponent("proton-drive", isDirectory: false)
        if fileManager.isExecutableFile(atPath: installed.path) {
            executable = installed
            return installed
        }
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/proton-drive" }
        if let path = (["/opt/homebrew/bin/proton-drive", "/usr/local/bin/proton-drive"] + pathCandidates)
            .first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            let url = URL(fileURLWithPath: path)
            executable = url
            return url
        }
        return try await download(to: installed)
    }

    func run(_ arguments: [String], timeout: Duration = .seconds(24 * 60 * 60)) async throws -> ProcessRunner.CapturedOutput {
        let url = try await executableURL()
        let output = await ProcessRunner.runCapturingOutput(url, arguments: arguments, timeout: timeout)
        if output.status == -1 { throw ProviderError.server(output.errorOutput) }
        return output
    }

    private func download(to destination: URL) async throws -> URL {
        #if arch(arm64)
        let platform = "darwin-arm64"
        let expected = "3f4125de5e41dcc7f4e0e07e8d60737aa18f35c6ecc1ba3fce47ea97b331857eefaf88e74671135af57122d4cb5439b817ec528f8df383550ac7810aeaf0217b"
        #else
        let platform = "darwin-x64"
        let expected = "a9fc830f38b680ef537fd92db75e1d6e345374f977efa523b145ccc7ec98570756f6ca32378d1bad6a84c9542f24ef43a63c6ec956e5dda9ca731b60b001a6e6"
        #endif
        let url = URL(string: "https://proton.me/download/drive/cli/\(Self.version)/\(platform)/proton-drive")!
        let temporary = fileManager.temporaryDirectory.appendingPathComponent("proton-drive-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ProviderError.server("Impossible de télécharger le CLI officiel Proton Drive.")
        }
        let digest = SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else {
            throw ProviderError.server("La vérification du CLI Proton Drive a échoué.")
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: temporary, options: .atomic)
        try fileManager.removeItemIfExists(at: destination)
        try fileManager.moveItem(at: temporary, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        executable = destination
        return destination
    }
}

extension FileManager {
    func removeItemIfExists(at url: URL) throws {
        if fileExists(atPath: url.path) { try removeItem(at: url) }
    }
}

#endif
