import XCTest
@testable import Fil

/// Le projet iOS compile directement des dossiers de `Sources/Fil`. Sans Xcode, ces tests vérifient
/// que le partage tient : même version, exclusions qui désignent de vrais fichiers, et aucune
/// bibliothèque propre au Mac importée sans garde dans ce qui part sur iOS.
final class IOSProjectTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func project() throws -> String {
        try String(contentsOf: root.appendingPathComponent("iOS/Fil.xcodeproj/project.pbxproj"), encoding: .utf8)
    }

    private func matches(_ pattern: String, in text: String) throws -> [[String]] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    /// Dossiers de `Sources/Fil` que le projet iOS compile, avec les fichiers qu'il en exclut.
    private func sharedFolders() throws -> [(folder: String, excluded: Set<String>)] {
        let text = try project()
        let folders = try matches(#"path = "\.\./Sources/Fil/(\w+)";"#, in: text).map { $0[0] }
        var excluded: [String: Set<String>] = [:]
        for match in try matches(#"/\* Exceptions for "(\w+)" folder in "Fil" target \*/ = \{\s*isa = PBXFileSystemSynchronizedBuildFileExceptionSet;\s*membershipExceptions = \(([^)]*)\);"#, in: text) {
            excluded[match[0]] = Set(try matches(#""([^"]+)""#, in: match[1]).map { $0[0] })
        }
        return folders.map { (folder: $0, excluded: excluded[$0] ?? []) }
    }

    func testMarketingVersionFollowsAppVersion() throws {
        let versions = try matches(#"MARKETING_VERSION = ([^;]+);"#, in: project()).map { $0[0] }
        XCTAssertFalse(versions.isEmpty)
        XCTAssertEqual(Set(versions), [AppVersion.current])
    }

    func testSharesTheModel() throws {
        let folders = try sharedFolders().map(\.folder)
        XCTAssertTrue(folders.contains("Model"))
        XCTAssertTrue(folders.contains("Design"))
    }

    /// Une exclusion qui ne désigne plus rien laisserait entrer sur iOS le fichier renommé.
    func testExcludedFilesExist() throws {
        for (folder, excluded) in try sharedFolders() {
            for file in excluded {
                let path = root.appendingPathComponent("Sources/Fil/\(folder)/\(file)").path
                XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Exclusion iOS sans fichier : \(folder)/\(file)")
            }
        }
    }

    /// AppKit, NetFS et libcurl n'existent pas sur iOS : dans un fichier partagé, leur import est gardé par `#if os(macOS)`.
    func testSharedFilesGuardMacOnlyImports() throws {
        let macOnly: Set<String> = ["import AppKit", "import NetFS", "import CCurl"]
        for (folder, excluded) in try sharedFolders() {
            let base = root.appendingPathComponent("Sources/Fil/\(folder)")
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relative = String(url.standardizedFileURL.path.dropFirst(base.standardizedFileURL.path.count + 1))
                guard !excluded.contains(relative) else { continue }
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                for (index, line) in lines.enumerated() where macOnly.contains(line) {
                    let guardLine = lines[..<index].last { !$0.hasPrefix("import ") }
                    XCTAssertEqual(guardLine, "#if os(macOS)", "\(folder)/\(relative) importe « \(line) » sans garde, alors qu'il est compilé pour iOS.")
                }
            }
        }
    }
}
