import XCTest
@testable import BenitoKit

final class BenitoKitTests: XCTestCase {
    func testVersion() {
        XCTAssertFalse(BenitoKit.version.isEmpty)
    }

    func testInMemoryStoreAppliesEventUpsertAndOutbox() async throws {
        let store = InMemoryStore()
        let childId = UUID()
        let event = EventDTO(
            id: UUID(),
            childId: childId,
            type: EventType.diaper.rawValue,
            subtype: "wet",
            startedAt: Date(),
            endedAt: nil,
            amountValue: nil,
            amountUnit: nil,
            side: nil,
            notes: nil,
            payloadJson: nil,
            createdBy: UUID(),
            createdAt: Date(),
            updatedAt: Date(),
            deletedAt: nil
        )
        let payload = try BenitoJSON.encoder.encode(event)
        let json = try BenitoJSON.decoder.decode(JSONValue.self, from: payload)
        let envelope = SyncEnvelopeDTO(type: SyncMessageType.eventUpsert.rawValue, payload: json, at: Date(), clientId: nil)
        try await store.applySyncEnvelope(envelope)
        let rows = try await store.events(childId: childId, limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.subtype, "wet")

        let id = try await store.enqueueOutbox(method: "POST", path: "/events", body: payload)
        let pending = try await store.pendingOutbox()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.id, id)
        try await store.deleteOutbox(id: id)
        let afterDelete = try await store.pendingOutbox()
        XCTAssertTrue(afterDelete.isEmpty)

        let glance = try await store.localBabyState(childId: childId)
        XCTAssertEqual(glance.lastDiaper?.id, event.id)
    }

    #if canImport(GRDB)
    func testGRDBStoreRoundTrip() async throws {
        let store = try GRDBStore(inMemory: ())
        let child = ChildDTO(
            id: UUID(),
            familyId: UUID(),
            name: "Sam",
            birthdate: nil,
            sex: nil,
            createdAt: Date()
        )
        try await store.upsertChild(child)
        let kids = try await store.children()
        XCTAssertEqual(kids.count, 1)

        let event = EventDTO(
            id: UUID(),
            childId: child.id,
            type: EventType.feedBottle.rawValue,
            subtype: "formula",
            startedAt: Date(),
            endedAt: nil,
            amountValue: 3,
            amountUnit: "oz",
            side: nil,
            notes: nil,
            payloadJson: nil,
            createdBy: UUID(),
            createdAt: Date(),
            updatedAt: Date(),
            deletedAt: nil
        )
        try await store.upsertEvent(event)
        let glance = try await store.localBabyState(childId: child.id)
        XCTAssertEqual(glance.lastFeed?.id, event.id)

        _ = try await store.enqueueOutbox(method: "POST", path: "/events", body: Data("{}".utf8))
        let pendingOutbox = try await store.pendingOutbox()
        XCTAssertEqual(pendingOutbox.count, 1)
    }

    #endif

    func testTimerDTODecodesSide() throws {
        let json = Data("""
        {"id":"11111111-1111-1111-1111-111111111111","child_id":"22222222-2222-2222-2222-222222222222","kind":"feed_breast","started_at":"2026-09-26T04:00:00.000Z","started_by":"33333333-3333-3333-3333-333333333333","state":"running","stopped_at":null,"updated_at":"2026-09-26T04:00:00.000Z","side":"L"}
        """.utf8)
        let timer = try BenitoJSON.decoder.decode(TimerDTO.self, from: json)
        XCTAssertEqual(timer.kind, "feed_breast")
        XCTAssertEqual(timer.side, "L")
    }

    func testSyncURLUsesWSScheme() {
        let https = URL(string: "https://example.com:8443/")!
        let http = URL(string: "http://192.168.1.20:8080")!
        var comps = URLComponents(url: http, resolvingAgainstBaseURL: false)!
        comps.scheme = (comps.scheme?.lowercased() == "https") ? "wss" : "ws"
        comps.path = "/sync"
        XCTAssertEqual(comps.url?.absoluteString, "ws://192.168.1.20:8080/sync")
        var comps2 = URLComponents(url: https, resolvingAgainstBaseURL: false)!
        comps2.scheme = (comps2.scheme?.lowercased() == "https") ? "wss" : "ws"
        comps2.path = "/sync"
        XCTAssertEqual(comps2.url?.absoluteString, "wss://example.com:8443/sync")
    }

    func testDailySummaryDTODecodes() throws {
        let json = Data("""
        {"child_id":"11111111-1111-1111-1111-111111111111","from":"2026-09-25T00:00:00.000Z","to":"2026-09-26T00:00:00.000Z","day":"2026-09-25","feed_breast_count":2,"feed_breast_left":1,"feed_breast_right":1,"feed_bottle_count":1,"bottle_oz_total":3.0,"bottle_ml_total":0.0,"bottle_oz_equiv":3.0,"feed_solid_count":0,"diaper_wet":4,"diaper_dirty":1,"diaper_both":0,"diaper_other":0,"sleep_event_count":3,"sleep_hours":8.5,"pump_count":0,"medicine_count":0,"total_events":11}
        """.utf8)
        let s = try BenitoJSON.decoder.decode(DailySummaryDTO.self, from: json)
        XCTAssertEqual(s.diaperWet, 4)
        XCTAssertEqual(s.bottleOzTotal, 3.0)
        XCTAssertEqual(s.sleepHours, 8.5)
    }


    func testAPIClientErrorSurfacesServerBody() {
        let data = Data(#"{"error":"email required; password min 8 chars"}"#.utf8)
        XCTAssertEqual(data.count, 48)
        XCTAssertEqual(
            APIClientError.serverErrorMessage(from: data),
            "email required; password min 8 chars"
        )
        let err = APIClientError.httpStatus(400, data)
        XCTAssertEqual(err.errorDescription, "httpStatus 400: email required; password min 8 chars")
    }

}

