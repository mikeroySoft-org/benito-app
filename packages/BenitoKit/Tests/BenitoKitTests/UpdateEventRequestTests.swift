import XCTest
@testable import BenitoKit

final class UpdateEventRequestTests: XCTestCase {
    private func object(_ request: UpdateEventRequestDTO) throws -> [String: Any] {
        let data = try BenitoJSON.encoder.encode(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAllNilEncodesToEmptyObject() throws {
        let data = try BenitoJSON.encoder.encode(UpdateEventRequestDTO())
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{}")
    }

    func testOnlyProvidedFieldsAreEncoded() throws {
        let json = try object(UpdateEventRequestDTO(subtype: "breastmilk", amountValue: 4.5, amountUnit: "oz"))
        XCTAssertEqual(Set(json.keys), ["subtype", "amount_value", "amount_unit"])
        XCTAssertEqual(json["subtype"] as? String, "breastmilk")
        XCTAssertEqual(json["amount_value"] as? Double, 4.5)
        XCTAssertEqual(json["amount_unit"] as? String, "oz")
    }

    func testAllFieldsUseSnakeCaseKeys() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let json = try object(UpdateEventRequestDTO(
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            subtype: "wet",
            side: "L",
            amountValue: 2,
            amountUnit: "oz",
            notes: "spit up"
        ))
        XCTAssertEqual(
            Set(json.keys),
            ["started_at", "ended_at", "subtype", "side", "amount_value", "amount_unit", "notes"]
        )
    }

    func testDatesEncodeAsISO8601WithFractionalSeconds() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000.5)
        let json = try object(UpdateEventRequestDTO(startedAt: start, endedAt: start.addingTimeInterval(60)))
        XCTAssertEqual(json["started_at"] as? String, "2023-11-14T22:13:20.500Z")
        XCTAssertEqual(json["ended_at"] as? String, "2023-11-14T22:14:20.500Z")
        XCTAssertEqual(Set(json.keys), ["started_at", "ended_at"])
    }
}
