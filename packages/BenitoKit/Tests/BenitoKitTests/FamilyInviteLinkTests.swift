import CryptoKit
import Foundation
import XCTest
@testable import BenitoKit

final class FamilyInviteLinkTests: XCTestCase {
    private func invite(endpoints: [String]) -> FamilyInviteDTO {
        FamilyInviteDTO(
            id: "inv-1",
            secret: "s3cret_-abc",
            familyId: "fam",
            familyName: "Test Family",
            inviterName: "Alex",
            role: .caregiver,
            accessHours: 4,
            label: nil,
            createdAt: .now,
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            serverId: "srv",
            endpoints: endpoints
        )
    }

    func testRoundTripThroughURL() throws {
        let link = try XCTUnwrap(
            FamilyInviteLink(
                invite: invite(endpoints: ["https://host.tailnet.ts.net", "http://192.168.1.20:8081"]),
                currentServer: URL(string: "https://host.tailnet.ts.net/")!
            )
        )
        // LAN endpoint first, current server next, duplicates collapsed.
        XCTAssertEqual(link.endpoints.map(\.absoluteString), ["http://192.168.1.20:8081", "https://host.tailnet.ts.net"])
        let url = link.url
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "benito.mikeroysoft.com")
        XCTAssertEqual(url.path, "/join")
        XCTAssertTrue(url.fragment?.hasPrefix("p=") == true)
        XCTAssertNil(url.query, "the payload stays in the fragment, out of web server logs")
        let parsed = try XCTUnwrap(FamilyInviteLink(url: url))
        XCTAssertEqual(parsed, link)
        XCTAssertEqual(parsed.role, .caregiver)
        XCTAssertFalse(parsed.isExpired)
    }

    func testParsesFromPastedText() throws {
        let link = try XCTUnwrap(
            FamilyInviteLink(invite: invite(endpoints: []), currentServer: URL(string: "http://benito.local:8080")!)
        )
        let text = "Join our family in Benito: \(link.url.absoluteString) (expires Friday)"
        XCTAssertEqual(FamilyInviteLink(text: text), link)
        XCTAssertNil(FamilyInviteLink(text: "nothing here"))
        XCTAssertNil(FamilyInviteLink(url: URL(string: "benito://join?p=garbage")!))
    }

    func testAppSchemeFallbackStillParses() throws {
        let link = try XCTUnwrap(
            FamilyInviteLink(invite: invite(endpoints: []), currentServer: URL(string: "http://benito.local:8080")!)
        )
        let app = link.appURL
        XCTAssertEqual(app.scheme, "benito")
        XCTAssertEqual(app.host, "join")
        XCTAssertEqual(FamilyInviteLink(url: app), link)
        XCTAssertEqual(FamilyInviteLink(text: "Old build: \(app.absoluteString)"), link)
    }

    func testWebLinkVariants() throws {
        let link = try XCTUnwrap(
            FamilyInviteLink(invite: invite(endpoints: []), currentServer: URL(string: "http://benito.local:8080")!)
        )
        let p = FamilyInviteLink.encodePayload(link)
        for raw in [
            "https://benito.mikeroysoft.com/join#p=\(p)",
            "https://benito.mikeroysoft.com/join/#p=\(p)",
            "https://Benito.MikeroySoft.com/join#p=\(p)",
            "https://benito.mikeroysoft.com/join#\(p)",
            "https://benito.mikeroysoft.com/join?p=\(p)",
        ] {
            XCTAssertEqual(FamilyInviteLink(url: try XCTUnwrap(URL(string: raw))), link, raw)
        }
        // Other hosts and paths are not invites.
        XCTAssertNil(FamilyInviteLink(url: try XCTUnwrap(URL(string: "https://example.com/join#p=\(p)"))))
        XCTAssertNil(FamilyInviteLink(url: try XCTUnwrap(URL(string: "https://benito.mikeroysoft.com/privacy#p=\(p)"))))
        XCTAssertNil(FamilyInviteLink(url: try XCTUnwrap(URL(string: "http://benito.mikeroysoft.com/join#p=\(p)"))))
        XCTAssertNil(FamilyInviteLink(url: try XCTUnwrap(URL(string: "https://benito.mikeroysoft.com/join#p=garbage"))))
        // Pasted from Messages, with text around it.
        XCTAssertEqual(FamilyInviteLink(text: "Join us: https://benito.mikeroysoft.com/join#p=\(p) (expires Fri)"), link)
    }

    func testLooksLocal() {
        XCTAssertTrue(FamilyInviteLink.looksLocal(URL(string: "http://10.0.0.5:8080")!))
        XCTAssertTrue(FamilyInviteLink.looksLocal(URL(string: "http://172.20.1.1")!))
        XCTAssertTrue(FamilyInviteLink.looksLocal(URL(string: "http://mac-mini.local:8080")!))
        XCTAssertFalse(FamilyInviteLink.looksLocal(URL(string: "https://100.64.1.2")!))
        XCTAssertFalse(FamilyInviteLink.looksLocal(URL(string: "https://example.com")!))
    }

    func testDeviceSignatureVerifiesWithPublicKey() throws {
        let identity = EphemeralDeviceIdentity()
        let message = DeviceAuthMessage.make(deviceId: "dev", timestamp: 1_700_000_000)
        let sig = try XCTUnwrap(Data(base64Encoded: try identity.sign(message)))
        let pub = try P256.Signing.PublicKey(x963Representation: XCTUnwrap(Data(base64Encoded: try identity.publicKeyBase64())))
        XCTAssertTrue(pub.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: sig), for: message))
    }

    func testMeDecodesWithAndWithoutSharingFields() throws {
        let base = #"{"user":{"id":"8F1F7A7E-9E55-4E0B-9C37-2B2E0E9C1A11","name":"A","email":"a@b.c","created_at":"2026-01-01T00:00:00Z"},"family":null,"children":[]"#
        let old = try BenitoJSON.decoder.decode(MeResponseDTO.self, from: Data((base + "}").utf8))
        XCTAssertNil(old.role)
        let new = try BenitoJSON.decoder.decode(
            MeResponseDTO.self,
            from: Data((base + #","role":"caregiver","access_expires_at":"2026-01-02T00:00:00+00:00","has_device_key":true}"#).utf8)
        )
        XCTAssertEqual(new.role, .caregiver)
        XCTAssertEqual(new.hasDeviceKey, true)
        XCTAssertNotNil(new.accessExpiresAt)
    }
}
