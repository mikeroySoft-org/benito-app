import Foundation
import Observation
import Sparkle

/// The app's connection to Sparkle. A build without an update key (any source build) never
/// starts the updater, so nothing checks the feed and no update window can appear.
@MainActor
@Observable
final class UpdaterController {
    private static let publicKeyInfoKey = "SUPublicEDKey"

    let isConfigured: Bool
    /// "0.1.0 (1)".
    let currentVersion: String

    /// False while a check is in flight, and always false when not configured.
    private(set) var canCheckForUpdates = false

    /// Mirrors Sparkle's own setting, which Sparkle's first-run question can also change.
    private var automaticChecks = false

    // Sparkle holds its delegate weakly.
    @ObservationIgnored private let backupDelegate: UpdateBackupDelegate
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(model: ServerModel) {
        let bundle = Bundle.main
        currentVersion = Self.versionString(of: bundle)
        backupDelegate = UpdateBackupDelegate(model: model)
        let publicKey = bundle.object(forInfoDictionaryKey: Self.publicKeyInfoKey) as? String ?? ""
        isConfigured = !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard isConfigured else {
            controller = nil
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: backupDelegate,
            userDriverDelegate: nil
        )
        self.controller = controller
        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticChecks = updater.automaticallyChecksForUpdates
        observations = [
            updater.observe(\.canCheckForUpdates) { [weak self] updater, _ in
                let value = updater.canCheckForUpdates
                Task { @MainActor in
                    self?.canCheckForUpdates = value
                }
            },
            updater.observe(\.automaticallyChecksForUpdates) { [weak self] updater, _ in
                let value = updater.automaticallyChecksForUpdates
                Task { @MainActor in
                    self?.automaticChecks = value
                }
            },
        ]
    }

    var automaticallyChecksForUpdates: Bool {
        get { automaticChecks }
        set {
            automaticChecks = newValue
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    private static func versionString(of bundle: Bundle) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        case let (nil, build?): return build
        case (nil, nil): return "Unknown"
        }
    }
}
