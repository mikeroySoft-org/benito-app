import Foundation
import Observation

/// State of the Connections pane: the form, what this Mac's network and Tailscale look like, and
/// the results of testing each address.
@MainActor
@Observable
final class ConnectionsModel {
    var draft = ConnectionDraft(settings: [:])

    private(set) var lanPortCheck = LanPortCheck.valid(LanPortCheck.defaultPort)
    private(set) var localAddresses: [String] = []
    private(set) var tailscale = TailscaleLoadState.checking
    private(set) var tests: [String: ReachabilityResult] = [:]
    private(set) var isApplying = false
    private(set) var isTurningOnServe = false
    /// Why the last Turn On did not work, in Tailscale's words plus what to do about it.
    private(set) var serveError: String?

    private var settings: [String: String] = [:]
    private(set) var publicPort = 8080

    // MARK: - Derived state

    /// The address phones on the home network would use for this Mac.
    var lanAddress: String? { localAddresses.first }

    var plan: ConnectionPlan {
        ConnectionPlan.make(
            draft: draft,
            settings: settings,
            publicPort: publicPort,
            lanPort: lanPortCheck,
            lanAddress: lanAddress,
            tailscale: tailscale.serve
        )
    }

    /// An IP saved for invites that this Mac no longer has.
    var staleLanHost: String? {
        AdvertisedAddress.staleLanHost(
            in: AdvertisedAddress.list(from: settings["BENITO_PUBLIC_URLS"]),
            current: localAddresses
        )
    }

    var isTesting: Bool { tests.values.contains(.testing) }

    var serveCommandLine: String {
        TailscaleCLI.serveCommandLine(loopbackPort: publicPort)
    }

    // MARK: - Loading

    /// Starts the form over from what `benito.env` says now.
    func adopt(settings: [String: String], publicPort: Int) {
        self.settings = settings
        self.publicPort = publicPort
        draft = ConnectionDraft(settings: settings)
        validateLanPort()
    }

    func validateLanPort() {
        lanPortCheck = LanPortCheck.evaluate(
            draft.lanPortText,
            loopbackPort: publicPort,
            currentLanPort: ConnectionDraft.lanPort(in: settings)
        )
    }

    func refreshNetwork() async {
        localAddresses = LocalNetwork.privateIPv4Addresses()
        guard let cli = TailscaleCLI.locate() else {
            tailscale = .notInstalled
            return
        }
        do {
            tailscale = .loaded(try await cli.snapshot(loopbackPort: publicPort))
        } catch {
            tailscale = .unavailable(Self.message(for: error))
        }
    }

    // MARK: - Testing

    func test(_ address: String) async {
        tests[address] = .testing
        tests[address] = await HealthProbe.check(address)
    }

    func testAll(_ addresses: [String]) async {
        for address in addresses {
            tests[address] = .testing
        }
        await withTaskGroup(of: (String, ReachabilityResult).self) { group in
            for address in addresses {
                group.addTask { (address, await HealthProbe.check(address)) }
            }
            for await (address, result) in group {
                tests[address] = result
            }
        }
    }

    // MARK: - Changes

    func apply(to server: ServerModel) async {
        let changes = plan.changes
        guard !changes.isEmpty, !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        if await server.applySettings(changes) {
            tests = [:]
        }
    }

    /// Rewrites the saved home network address to the one this Mac has now, and nothing else.
    func updateAddress(on server: ServerModel) async {
        guard let lanAddress, !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        let addresses = AdvertisedAddress.replacingLanHosts(
            in: AdvertisedAddress.list(from: settings["BENITO_PUBLIC_URLS"]),
            with: lanAddress
        )
        if await server.applySettings(["BENITO_PUBLIC_URLS": addresses.joined(separator: ",")]) {
            tests = [:]
        }
    }

    func turnOnServe() async {
        guard let cli = TailscaleCLI.locate(), !isTurningOnServe else { return }
        isTurningOnServe = true
        defer { isTurningOnServe = false }
        serveError = nil
        do {
            try await cli.turnOnServe(loopbackPort: publicPort)
        } catch {
            serveError = Self.message(for: error)
        }
        await refreshNetwork()
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
