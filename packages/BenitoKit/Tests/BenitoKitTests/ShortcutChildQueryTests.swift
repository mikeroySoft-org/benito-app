import XCTest
@testable import BenitoKit

final class ShortcutChildQueryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "benito.tests.shortcut-child.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSuggestedEntitiesReturnsSavedChildren() {
        let sam = ShortcutChild(id: UUID(), name: "Sam")
        ShortcutChildStore.save([sam], to: defaults)
        let query = ShortcutChildQuery(children: ShortcutChildStore.load(from: defaults))
        XCTAssertEqual(query.suggestedEntities(), [sam])
    }

    func testEntitiesForIdentifiersPreservesOrderAndSkipsUnknown() {
        let sam = ShortcutChild(id: UUID(), name: "Sam")
        let rio = ShortcutChild(id: UUID(), name: "Rio")
        let query = ShortcutChildQuery(children: [sam, rio])
        XCTAssertEqual(query.entities(for: [rio.id, UUID(), sam.id]), [rio, sam])
        XCTAssertEqual(query.entities(for: [UUID()]), [])
    }

    func testLoadIgnoresIncompleteOrBlankCache() {
        XCTAssertEqual(ShortcutChildStore.load(from: defaults), [])

        defaults.set("not-a-uuid", forKey: ShortcutChildStore.idKey)
        defaults.set("Sam", forKey: ShortcutChildStore.nameKey)
        XCTAssertEqual(ShortcutChildStore.load(from: defaults), [])

        let id = UUID()
        defaults.set(id.uuidString, forKey: ShortcutChildStore.idKey)
        defaults.set("   ", forKey: ShortcutChildStore.nameKey)
        XCTAssertEqual(ShortcutChildStore.load(from: defaults), [])
    }

    func testSaveThenLoadRoundTripAndClear() {
        let sam = ShortcutChild(id: UUID(), name: "  Sam  ")
        ShortcutChildStore.save([sam], to: defaults)
        XCTAssertEqual(ShortcutChildStore.load(from: defaults), [ShortcutChild(id: sam.id, name: "Sam")])

        ShortcutChildStore.save([], to: defaults)
        XCTAssertEqual(ShortcutChildStore.load(from: defaults), [])
        XCTAssertNil(defaults.string(forKey: ShortcutChildStore.idKey))
        XCTAssertNil(defaults.string(forKey: ShortcutChildStore.nameKey))
    }

    func testSaveUsesTheFirstChildOnly() {
        let sam = ShortcutChild(id: UUID(), name: "Sam")
        let rio = ShortcutChild(id: UUID(), name: "Rio")
        ShortcutChildStore.save([sam, rio], to: defaults)
        XCTAssertEqual(ShortcutChildStore.load(from: defaults), [sam])
    }
}
