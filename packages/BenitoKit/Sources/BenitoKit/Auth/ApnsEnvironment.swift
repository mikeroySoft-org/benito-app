import Foundation

/// APNs environment the running binary is actually signed for.
///
/// Taken from `Entitlements.aps-environment` in the app's `embedded.mobileprovision`,
/// which is what ActivityKit tokens will use. A development-signed Xcode install is
/// `sandbox`. An App Store or TestFlight build (after the App Store Connect export)
/// is `production`. There is no provision on the Simulator, so that is `sandbox`.
public enum ApnsEnvironment: String, Sendable, Equatable {
    case sandbox
    case production

    /// The `apns_env` value `POST /live-activity/tokens` expects.
    public var tokenEnvironment: String { rawValue }

    /// Environment of this process's signed app binary.
    public static var current: ApnsEnvironment {
        resolve(provisionData: embeddedProvision(in: .main))
    }

    /// `production` only when the profile's `aps-environment` is production; anything
    /// else (development, missing, unreadable) is `sandbox`.
    public static func resolve(provisionData: Data?) -> ApnsEnvironment {
        guard let provisionData, let profile = provisioningProfilePlist(from: provisionData) else {
            return .sandbox
        }
        return fromProvisioningProfile(profile)
    }

    public static func fromProvisioningProfile(_ profile: [String: Any]) -> ApnsEnvironment {
        let entitlements = profile["Entitlements"] as? [String: Any] ?? [:]
        return fromApsEnvironment(entitlements["aps-environment"] as? String)
    }

    public static func fromApsEnvironment(_ value: String?) -> ApnsEnvironment {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "production", "prod": .production
        default: .sandbox
        }
    }

    public static func embeddedProvision(in bundle: Bundle) -> Data? {
        bundle.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }
    }

    /// `embedded.mobileprovision` is a CMS (PKCS#7) blob with a plist in the payload.
    static func provisioningProfilePlist(from data: Data) -> [String: Any]? {
        // Latin-1 so binary CMS bytes around the XML don't fail UTF-8 decoding.
        guard let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>")
        else { return nil }
        let xml = String(text[start.lowerBound..<end.upperBound])
        guard let xmlData = xml.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: xmlData, format: nil)
        else { return nil }
        return plist as? [String: Any]
    }
}
