import XCTest
@testable import BenitoKit

/// The app's saved Server URL is the primary; other addresses of the same server
/// (remembered `advertised_urls`, Bonjour) are only used while the primary doesn't answer.
final class ServerRouteTests: XCTestCase {
    private let tailnet = URL(string: "https://ultron.example.ts.net")!
    private let lan = URL(string: "http://10.0.10.42:8082")!
    private let serverId = "server-a"

    private func info(_ id: String, urls: [URL] = []) -> ServerInfoDTO {
        ServerInfoDTO(
            service: "benito-server",
            version: "0.1.0",
            serverId: id,
            advertisedUrls: urls.map(\.absoluteString),
            features: []
        )
    }

    /// `up` maps origin → the server answering there; everything else is unreachable.
    private func choose(up: [URL: ServerInfoDTO], candidates: [URL], serverId: String?) async -> ServerRouteChoice {
        await ServerRoute.choose(
            primary: tailnet,
            candidates: { candidates },
            serverId: serverId,
            probe: { url in up[url] }
        )
    }

    func testPrimaryDownAndLANUpUsesLAN() async {
        let choice = await choose(up: [lan: info(serverId)], candidates: [lan], serverId: serverId)
        XCTAssertEqual(choice.route, .fallback(lan))
        XCTAssertEqual(choice.route.url, lan)
        XCTAssertEqual(choice.route.label, "home network")
    }

    func testPrimaryUpIsPreferredOverLAN() async {
        let choice = await choose(
            up: [tailnet: info(serverId), lan: info(serverId)],
            candidates: [lan],
            serverId: serverId
        )
        XCTAssertEqual(choice.route, .primary(tailnet))
    }

    func testReturnsToPrimaryWhenItRecovers() async {
        let down = await choose(up: [lan: info(serverId)], candidates: [lan], serverId: serverId)
        XCTAssertEqual(down.route, .fallback(lan))
        let recovered = await choose(
            up: [tailnet: info(serverId, urls: [lan, tailnet]), lan: info(serverId)],
            candidates: [lan],
            serverId: serverId
        )
        XCTAssertEqual(recovered.route, .primary(tailnet))
        XCTAssertEqual(recovered.primaryInfo?.advertisedUrls, [lan.absoluteString, tailnet.absoluteString])
    }

    func testRefusesLANServerWithDifferentIdentity() async {
        let choice = await choose(up: [lan: info("someone-elses-server")], candidates: [lan], serverId: serverId)
        XCTAssertEqual(choice.route, .primary(tailnet))
    }

    func testRefusesFallbackWhenIdentityWasNeverLearned() async {
        let choice = await choose(up: [lan: info(serverId)], candidates: [lan], serverId: nil)
        XCTAssertEqual(choice.route, .primary(tailnet))
    }

    func testSkipsMismatchedCandidateForMatchingOne() async {
        let other = URL(string: "http://10.0.10.99:8082")!
        let choice = await choose(
            up: [other: info("neighbor"), lan: info(serverId)],
            candidates: [other, lan],
            serverId: serverId
        )
        XCTAssertEqual(choice.route, .fallback(lan))
    }

    func testDoesNotLookForCandidatesWhilePrimaryAnswers() async {
        let looked = expectation(description: "candidates")
        looked.isInverted = true
        _ = await ServerRoute.choose(
            primary: tailnet,
            candidates: { looked.fulfill(); return [self.lan] },
            serverId: serverId,
            probe: { _ in self.info(self.serverId) }
        )
        await fulfillment(of: [looked], timeout: 0.1)
    }

    func testOnlyTransportFailuresTriggerFallback() {
        let offline = APIClientError.transport(URLError(.cannotConnectToHost))
        XCTAssertTrue(ServerRoute.isUnreachable(offline))
        XCTAssertTrue(ServerRoute.isUnreachable(URLError(.timedOut)))
        XCTAssertFalse(ServerRoute.isUnreachable(APIClientError.httpStatus(401, nil)))
        XCTAssertFalse(ServerRoute.isUnreachable(APIClientError.httpStatus(403, nil)))
        XCTAssertFalse(ServerRoute.isUnreachable(APIClientError.httpStatus(500, nil)))
    }

    func testFallbackLabelNamesHostOutsideHomeNetwork() {
        XCTAssertEqual(ServerRoute.fallback(URL(string: "https://backup.example.com")!).label, "backup.example.com")
        XCTAssertEqual(ServerRoute.fallback(URL(string: "http://benito.local:8082")!).label, "home network")
        XCTAssertNil(ServerRoute.primary(tailnet).label)
    }

    func testRouteChangeKeepsSessionToken() async {
        let api = APIClient(baseURL: tailnet, token: "t")
        await api.route(to: lan)
        let base = await api.baseURL
        let token = await api.token
        XCTAssertEqual(base, lan)
        XCTAssertEqual(token, "t")
    }
}
