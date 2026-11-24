import Foundation
import Sparkle

/// Takes a server snapshot after someone agrees to install an app update and before the app
/// relaunches into the new version.
@MainActor
final class UpdateBackupDelegate: NSObject, SPUUpdaterDelegate {
    /// A stuck backup must not hold an update back forever.
    static let backupLimit: Duration = .seconds(60)

    private let model: ServerModel

    init(model: ServerModel) {
        self.model = model
        super.init()
    }

    // Sparkle calls its delegate on the main thread but does not say so in its headers, hence
    // nonisolated plus a hop. Always postponing keeps the answer free of main-actor state.
    nonisolated func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        Task { @MainActor in
            await self.backUpBeforeInstall()
            installHandler()
        }
        return true
    }

    private func backUpBeforeInstall() async {
        guard model.isRunning, model.backupsEnabled else { return }
        // Whichever finishes first ends the wait; a backup past the limit is left to finish alone.
        let (finished, signal) = AsyncStream.makeStream(of: Void.self)
        let backup = Task { [model] in
            await model.backUpNow()
            signal.yield()
        }
        let limit = Task {
            try? await Task.sleep(for: Self.backupLimit)
            signal.yield()
        }
        for await _ in finished {
            break
        }
        backup.cancel()
        limit.cancel()
    }
}
