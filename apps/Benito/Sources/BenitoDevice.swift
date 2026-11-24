import UIKit

/// "iPhone" or "iPad", for copy that names the device the app is running on.
@MainActor
enum BenitoDevice {
    static let name = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
}
