import XCTest
@testable import BenitoKit

/// Moving on-device history to a server: every entry lands once, even across retries.
final class LocalToServerUploaderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    /// Stand-in server. `honorsIds` = a server with `client_event_ids`; otherwise it mints ids.
    private actor FakeServer: ServerEventCreating {
        let honorsIds: Bool
        var failAfter: Int?
        private(set) var stored: [UUID: EventDTO] = [:]
        private(set) var calls = 0

        init(honorsIds: Bool, failAfter: Int? = nil) {
            self.honorsIds = honorsIds
            self.failAfter = failAfter
        }

        func heal() { failAfter = nil }

        func createEvent(_ request: CreateEventRequestDTO) async throws -> EventDTO {
            if let failAfter, calls >= failAfter { throw APIClientError.transport(URLError(.networkConnectionLost)) }
            calls += 1
            if honorsIds, let id = request.id, let existing = stored[id] { return existing }
            let event = EventDTO(
                id: honorsIds ? (request.id ?? UUID()) : UUID(),
                childId: request.childId,
                type: request.type,
                subtype: request.subtype,
                startedAt: request.startedAt ?? .now,
                endedAt: request.endedAt,
                amountValue: request.amountValue,
                amountUnit: request.amountUnit,
                side: request.side,
                notes: request.notes,
                payloadJson: request.payloadJson,
                createdBy: UUID(),
                createdAt: .now,
                updatedAt: .now,
                deletedAt: nil
            )
            stored[event.id] = event
            return event
        }
    }

    private func seededStore(count: Int) async throws -> (any BenitoStore, UUID, [UUID]) {
        let store = try LocalStoreFactory.makeGRDB(path: ":memory:")
        let service = LocalBenitoService(store: store, clock: { self.t0 })
        let child = try await service.createProfile(yourName: "M", familyName: "F", childName: "B").children[0].id
        var ids: [UUID] = []
        for i in 0..<count {
            let e = try await service.createEvent(CreateEventRequestDTO(
                childId: child, type: "diaper", subtype: "wet", startedAt: t0.addingTimeInterval(Double(-60 * (i + 1)))
            ))
            ids.append(e.id)
        }
        let deleted = try await service.createEvent(CreateEventRequestDTO(childId: child, type: "note", notes: "oops"))
        try await service.deleteEvent(id: deleted.id)
        return (store, child, ids)
    }

    func testUploadsEveryLiveEntryOnceKeepingIds() async throws {
        let (store, localChild, ids) = try await seededStore(count: 3)
        let serverChild = UUID()
        let server = FakeServer(honorsIds: true)
        let n = try await LocalToServerUploader(store: store, server: server).upload(localChildId: localChild, serverChildId: serverChild)
        XCTAssertEqual(n, 3, "deleted entries stay behind")
        let stored = await server.stored
        XCTAssertEqual(Set(stored.keys), Set(ids))
        XCTAssertTrue(stored.values.allSatisfy { $0.childId == serverChild })
        let left = try await store.events(childId: localChild, from: .distantPast, to: .distantFuture).filter { $0.deletedAt == nil }
        XCTAssertTrue(left.isEmpty)
        let moved = try await store.events(childId: serverChild, from: .distantPast, to: .distantFuture)
        XCTAssertEqual(moved.count, 3)

        // A second run (say, the app relaunched) sends nothing.
        let again = try await LocalToServerUploader(store: store, server: server).upload(localChildId: localChild, serverChildId: serverChild)
        XCTAssertEqual(again, 0)
        let calls = await server.calls
        XCTAssertEqual(calls, 3)
    }

    func testResumesAfterDroppedConnectionWithoutDuplicates() async throws {
        let (store, localChild, ids) = try await seededStore(count: 5)
        let serverChild = UUID()
        let server = FakeServer(honorsIds: true, failAfter: 2)
        let uploader = LocalToServerUploader(store: store, server: server)
        do {
            try await uploader.upload(localChildId: localChild, serverChildId: serverChild)
            XCTFail("expected the dropped connection to surface")
        } catch {}
        var stored = await server.stored
        XCTAssertEqual(stored.count, 2)

        await server.heal()
        let rest = try await uploader.upload(localChildId: localChild, serverChildId: serverChild)
        XCTAssertEqual(rest, 3)
        stored = await server.stored
        XCTAssertEqual(Set(stored.keys), Set(ids))
    }

    func testOlderServerThatMintsIdsStillNeverDuplicates() async throws {
        let (store, localChild, _) = try await seededStore(count: 2)
        let serverChild = UUID()
        let server = FakeServer(honorsIds: false)
        let uploader = LocalToServerUploader(store: store, server: server)
        try await uploader.upload(localChildId: localChild, serverChildId: serverChild)
        try await uploader.upload(localChildId: localChild, serverChildId: serverChild)
        let stored = await server.stored
        XCTAssertEqual(stored.count, 2)
        let visible = try await store.events(childId: serverChild, from: .distantPast, to: .distantFuture)
        XCTAssertEqual(Set(visible.map(\.id)), Set(stored.keys), "local copies are replaced by the server's")
    }

    func testPendingMigrationRoundTrips() {
        let defaults = UserDefaults(suiteName: "uploader-tests-\(UUID().uuidString)")!
        XCTAssertNil(PendingServerMigration.load(defaults))
        var pending = PendingServerMigration(serverURL: "http://192.168.1.20:8082", localChildId: UUID())
        pending.save(defaults)
        XCTAssertEqual(PendingServerMigration.load(defaults), pending)
        pending.serverChildId = UUID()
        pending.save(defaults)
        XCTAssertEqual(PendingServerMigration.load(defaults)?.serverChildId, pending.serverChildId)
        PendingServerMigration.clear(defaults)
        XCTAssertNil(PendingServerMigration.load(defaults))

        XCTAssertEqual(BenitoMode.current(defaults), .server, "no key = existing server users")
        BenitoMode.set(.onDevice, defaults)
        XCTAssertEqual(BenitoMode.current(defaults), .onDevice)
        BenitoMode.set(.server, defaults)
        XCTAssertNil(defaults.string(forKey: BenitoMode.defaultsKey))
    }
}
