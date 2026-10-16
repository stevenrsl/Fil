import XCTest
@testable import Fil

final class AppVersionTests: XCTestCase {
    func testVersionIsSemantic() {
        let parts = AppVersion.current.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil })
        XCTAssertEqual(AppVersion.display, "Fil \(AppVersion.current)")
    }

    /// `Tools/bundle.sh` réécrit la version, mais le fichier du dépôt ne doit pas mentir pour autant.
    func testSupportInfoPlistFollowsAppVersion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Support/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, AppVersion.current)
    }
}
