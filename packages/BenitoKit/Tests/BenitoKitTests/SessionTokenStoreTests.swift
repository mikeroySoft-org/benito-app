import XCTest
@testable import BenitoKit

final class SessionTokenStoreTests: XCTestCase {
    func testAccountKeyStripsDefaultPortCaseAndPath() throws {
        XCTAssertEqual(
            SessionTokenStoreKey.account(for: try XCTUnwrap(URL(string: "https://Host.Example:443/api/"))),
            "https://host.example"
        )
        XCTAssertEqual(
            SessionTokenStoreKey.account(for: try XCTUnwrap(URL(string: "HTTP://host.example:80"))),
            "http://host.example"
        )
        XCTAssertEqual(
            SessionTokenStoreKey.account(for: try XCTUnwrap(URL(string: "http://127.0.0.1:8080/"))),
            "http://127.0.0.1:8080"
        )
        XCTAssertEqual(
            SessionTokenStoreKey.account(for: try XCTUnwrap(URL(string: "https://host.example:8443/x?y=1#z"))),
            "https://host.example:8443"
        )
    }

    func testInMemoryStoreIsolatesOrigins() throws {
        let store = InMemorySessionTokenStore()
        let a = try XCTUnwrap(URL(string: "https://a.example"))
        let b = try XCTUnwrap(URL(string: "http://127.0.0.1:8080"))

        try store.setToken("token-a", for: a)
        try store.setToken("token-b", for: b)
        XCTAssertEqual(try store.token(for: URL(string: "https://A.example:443/")!), "token-a")
        XCTAssertEqual(try store.token(for: b), "token-b")

        try store.deleteToken(for: a)
        XCTAssertNil(try store.token(for: a))
        XCTAssertEqual(try store.token(for: b), "token-b")
    }

    #if canImport(Security)
    private var keychainStore: KeychainSessionTokenStore?
    private let keychainServers = [
        URL(string: "https://a.example")!,
        URL(string: "https://b.example:8443")!,
    ]

    override func tearDown() {
        if let keychainStore {
            for server in keychainServers {
                try? keychainStore.deleteToken(for: server)
            }
        }
        keychainStore = nil
        super.tearDown()
    }

    func testKeychainRoundTripAndOriginIsolation() throws {
        let store = KeychainSessionTokenStore(service: "com.mikeroysoft.benito.tests.\(UUID())")
        keychainStore = store
        let a = keychainServers[0]
        let b = keychainServers[1]

        do {
            try store.setToken("first", for: a)
        } catch SessionTokenStoreError.keychain(-34018) {
            throw XCTSkip("Keychain unavailable (errSecMissingEntitlement) in unsigned test host")
        } catch SessionTokenStoreError.keychain(-25308) {
            throw XCTSkip("Keychain locked / interaction not allowed in this session (errSecInteractionNotAllowed)")
        }

        XCTAssertEqual(try store.token(for: a), "first")
        XCTAssertNil(try store.token(for: b))

        try store.setToken("second", for: a)
        try store.setToken("other", for: b)
        XCTAssertEqual(try store.token(for: a), "second")
        XCTAssertEqual(try store.token(for: b), "other")

        try store.deleteToken(for: a)
        XCTAssertNil(try store.token(for: a))
        XCTAssertEqual(try store.token(for: b), "other")

        // Deleting a missing item is not an error.
        try store.deleteToken(for: a)
    }
    #endif
}
