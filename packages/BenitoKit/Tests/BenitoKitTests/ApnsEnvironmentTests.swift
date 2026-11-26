import XCTest
@testable import BenitoKit

final class ApnsEnvironmentTests: XCTestCase {
    func testApsEnvironmentStrings() {
        XCTAssertEqual(ApnsEnvironment.fromApsEnvironment("production"), .production)
        XCTAssertEqual(ApnsEnvironment.fromApsEnvironment("PRODUCTION"), .production)
        XCTAssertEqual(ApnsEnvironment.fromApsEnvironment(" prod "), .production)
        XCTAssertEqual(ApnsEnvironment.fromApsEnvironment("development"), .sandbox)
        XCTAssertEqual(ApnsEnvironment.fromApsEnvironment("sandbox"), .sandbox)
        XCTAssertEqual(ApnsEnvironment.fromApsEnvironment("Development"), .sandbox)
        XCTAssertEqual(ApnsEnvironment.fromApsEnvironment(nil), .sandbox)
        XCTAssertEqual(ApnsEnvironment.fromApsEnvironment(""), .sandbox)
        XCTAssertEqual(ApnsEnvironment.fromApsEnvironment("unknown"), .sandbox)
    }

    func testProvisioningProfileEntitlements() throws {
        XCTAssertEqual(
            ApnsEnvironment.fromProvisioningProfile(try profile(aps: "production")),
            .production
        )
        XCTAssertEqual(
            ApnsEnvironment.fromProvisioningProfile(try profile(aps: "development")),
            .sandbox
        )
        XCTAssertEqual(
            ApnsEnvironment.fromProvisioningProfile(["Name": "No entitlements"]),
            .sandbox
        )
        XCTAssertEqual(
            ApnsEnvironment.fromProvisioningProfile(["Entitlements": ["application-identifier": "TEAM.app"]]),
            .sandbox
        )
    }

    func testEmbeddedProvisionExtractsPlistFromCMSWrapper() throws {
        let production = try cmsWrapped(profileXML(aps: "production"))
        let development = try cmsWrapped(profileXML(aps: "development"))
        XCTAssertEqual(ApnsEnvironment.resolve(provisionData: production), .production)
        XCTAssertEqual(ApnsEnvironment.resolve(provisionData: development), .sandbox)
        XCTAssertEqual(ApnsEnvironment.resolve(provisionData: Data("not a profile".utf8)), .sandbox)
        XCTAssertEqual(ApnsEnvironment.resolve(provisionData: nil), .sandbox)
    }

    func testRawValueIsWhatTheServerExpects() {
        XCTAssertEqual(ApnsEnvironment.production.rawValue, "production")
        XCTAssertEqual(ApnsEnvironment.sandbox.rawValue, "sandbox")
    }

    private func profile(aps: String) throws -> [String: Any] {
        let data = try profileXML(aps: aps).data(using: .utf8).orThrow()
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    private func profileXML(aps: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Name</key>
            <string>Test Profile</string>
            <key>Entitlements</key>
            <dict>
                <key>application-identifier</key>
                <string>PVF5R8D8Q2.com.mikeroysoft.benito</string>
                <key>aps-environment</key>
                <string>\(aps)</string>
            </dict>
        </dict>
        </plist>
        """
    }

    /// The on-device `embedded.mobileprovision` is a CMS (PKCS#7) blob with a plist inside.
    private func cmsWrapped(_ xml: String) throws -> Data {
        var data = Data("\u{00}\u{01}fake-cms-header".utf8)
        data.append(contentsOf: xml.utf8)
        data.append(contentsOf: Data([0xFF, 0x00, 0x80]))
        return data
    }
}

private extension Optional where Wrapped == Data {
    func orThrow(file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        try XCTUnwrap(self, file: file, line: line)
    }
}
