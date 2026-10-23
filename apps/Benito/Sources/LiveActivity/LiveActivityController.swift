import ActivityKit
import BenitoKit
import SwiftUI
import UIKit

enum LiveActivitySettings {
    /// `@AppStorage` key for the Settings toggle; defaults to on.
    static let enabledKey = "benito.liveActivityEnabled"
}

/// Keeps a single Benito Live Activity (Lock Screen + Dynamic Island) for the running
/// or paused timer. No active timer ends it immediately so the island cannot keep
/// counting. Starts with `pushType: .token` so a suspended partner phone can receive
/// an ActivityKit `end` push when someone else stops the timer. Push delivery is
/// server-gated (no-op until APNs env is set on the host).
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private typealias ContentState = BenitoActivityAttributes.ContentState

    /// Hex ActivityKit update token + Activity.id for server registration.
    typealias PushTokenHandler = @MainActor (String, String) -> Void

    /// The system ends Live Activities after 8h; refresh before that when the app is in front.
    private static let maxAge: TimeInterval = 7 * 3600
    /// Age after which an activity that disappeared is assumed to have expired, not been dismissed.
    private static let systemLifetime: TimeInterval = 8 * 3600
    private static let activityIdKey = "benito.liveActivity.id"
    private static let startedAtKey = "benito.liveActivity.startedAt"

    private var activity: Activity<BenitoActivityAttributes>?
    private var currentState: ContentState?
    /// Content the user swiped away; don't re-request until something changes.
    private var dismissedState: ContentState?
    private var adoptedExisting = false
    private var loggedAuthorizationDisabled = false
    /// Serializes async `update`/`end` calls so they apply in order.
    private var tail: Task<Void, Never>?
    /// Latest content waiting to flush — coalesces rapid sync so the Task chain cannot grow unbounded.
    private var pendingUpdate: (Activity<BenitoActivityAttributes>, ContentState)?
    private let defaults = UserDefaults.standard
    /// Forwards ActivityKit push tokens to the server (set while signed in).
    private var pushTokenHandler: PushTokenHandler?
    private var pushTokenTask: Task<Void, Never>?

    private init() {}

    /// Install or clear the server registration callback for ActivityKit update tokens.
    func setPushTokenHandler(_ handler: PushTokenHandler?) {
        pushTokenHandler = handler
        // If an activity is already live, start (or restart) watching with the new handler.
        if let activity, handler != nil {
            watchPushTokens(activity)
        }
        if handler == nil {
            pushTokenTask?.cancel()
            pushTokenTask = nil
        }
    }

    func sync(state: BabyStateDTO?, childName: String, signedIn: Bool, enabled: Bool) {
        adoptExistingIfNeeded()
        dropIfEndedExternally()

        guard signedIn, enabled, let content = ContentState.from(state: state) else {
            dismissedState = nil
            if activity != nil || !Activity<BenitoActivityAttributes>.activities.isEmpty {
                let reason = !signedIn ? "signed out" : (!enabled ? "disabled in settings" : "nothing to show")
                endAll(reason: reason)
            }
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            if !loggedAuthorizationDisabled {
                BenitoLog.ui.notice("liveActivity skipped: Live Activities disabled in system settings")
                loggedAuthorizationDisabled = true
            }
            return
        }
        loggedAuthorizationDisabled = false

        let trimmedName = childName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? "Baby" : trimmedName
        // `Activity.request` only succeeds while the app is in the foreground.
        let inForeground = UIApplication.shared.applicationState != .background

        guard let activity else {
            if content == dismissedState { return }
            guard inForeground else {
                BenitoLog.ui.notice("liveActivity start deferred: app in background")
                return
            }
            start(name: name, content: content)
            return
        }

        if inForeground, activity.attributes.childName != name || isNearExpiry(activity) {
            restart(activity, name: name, content: content)
        } else if content != currentState {
            update(activity, content: content)
        }
    }

    // MARK: - Lifecycle

    private func start(name: String, content: ContentState) {
        do {
            // `.token` opts into ActivityKit push updates / end (sandbox tokens while
            // developing; server stores apns_env and no-ops until the .p8 is configured).
            let started = try Activity.request(
                attributes: BenitoActivityAttributes(childName: name),
                content: ActivityContent(state: content, staleDate: nil),
                pushType: .token
            )
            activity = started
            currentState = content
            dismissedState = nil
            defaults.set(started.id, forKey: Self.activityIdKey)
            defaults.set(Date.now.timeIntervalSince1970, forKey: Self.startedAtKey)
            BenitoLog.ui.notice("liveActivity started \(started.id, privacy: .public) timer=\(content.timerKind ?? "none", privacy: .public) pushType=token")
            watchPushTokens(started)
        } catch {
            BenitoLog.ui.error("liveActivity start failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func watchPushTokens(_ activity: Activity<BenitoActivityAttributes>) {
        pushTokenTask?.cancel()
        pushTokenTask = Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                BenitoLog.ui.notice(
                    "liveActivity pushToken \(activity.id, privacy: .public) bytes=\(tokenData.count, privacy: .public)"
                )
                self?.pushTokenHandler?(hex, activity.id)
            }
        }
    }

    private func update(_ target: Activity<BenitoActivityAttributes>, content: ContentState) {
        currentState = content
        pendingUpdate = (target, content)
        enqueue { [weak self] in
            guard let self else { return }
            guard let pending = self.pendingUpdate else { return }
            self.pendingUpdate = nil
            await LiveActivitySync.update(pending.0, content: pending.1)
        }
    }

    private func restart(_ old: Activity<BenitoActivityAttributes>, name: String, content: ContentState) {
        BenitoLog.ui.notice("liveActivity restarting \(old.id, privacy: .public) (refresh before 8h limit or child renamed)")
        activity = nil
        currentState = nil
        pendingUpdate = nil
        clearStoredStart()
        end([old])
        start(name: name, content: content)
    }

    private func endAll(reason: String) {
        let all = Activity<BenitoActivityAttributes>.activities
        activity = nil
        currentState = nil
        pendingUpdate = nil
        pushTokenTask?.cancel()
        pushTokenTask = nil
        clearStoredStart()
        BenitoLog.ui.notice("liveActivity ending \(all.count, privacy: .public) activity(ies): \(reason, privacy: .public)")
        end(all)
    }

    private func end(_ activities: [Activity<BenitoActivityAttributes>]) {
        guard !activities.isEmpty else { return }
        enqueue {
            await LiveActivitySync.end(activities)
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    /// Waits until the queued update/end has been sent to ActivityKit.
    func flush() async {
        await tail?.value
    }

    // MARK: - Existing activity bookkeeping

    /// On first sync after launch, reuse a still-running activity and end any duplicates.
    private func adoptExistingIfNeeded() {
        guard !adoptedExisting else { return }
        adoptedExisting = true

        let all = Activity<BenitoActivityAttributes>.activities
        guard let first = all.first(where: { LiveActivitySync.isLive($0) }) else {
            clearStoredStart()
            end(all)
            return
        }
        activity = first
        currentState = first.content.state
        BenitoLog.ui.notice("liveActivity reusing \(first.id, privacy: .public)")
        watchPushTokens(first)
        let duplicates = all.filter { $0.id != first.id }
        if !duplicates.isEmpty {
            BenitoLog.ui.notice("liveActivity ending \(duplicates.count, privacy: .public) duplicate(s)")
            end(duplicates)
        }
    }

    /// Forget an activity the system ended (8h limit) or the user dismissed from the Lock Screen.
    private func dropIfEndedExternally() {
        guard let activity, !LiveActivitySync.isLive(activity) else { return }
        let expired = storedStart(for: activity.id).map { Date.now.timeIntervalSince($0) >= Self.systemLifetime } ?? true
        BenitoLog.ui.notice("liveActivity \(activity.id, privacy: .public) no longer active (\(expired ? "expired" : "dismissed", privacy: .public))")
        // A user dismissal sticks until the content changes; an expiry restarts on the next sync.
        dismissedState = expired ? nil : currentState
        self.activity = nil
        currentState = nil
        pendingUpdate = nil
        pushTokenTask?.cancel()
        pushTokenTask = nil
        clearStoredStart()
    }

    private func isNearExpiry(_ activity: Activity<BenitoActivityAttributes>) -> Bool {
        // Unknown start (e.g. adopted from an older build) → treat as old so it gets a fresh 8h window.
        guard let started = storedStart(for: activity.id) else { return true }
        return Date.now.timeIntervalSince(started) >= Self.maxAge
    }

    private func storedStart(for id: String) -> Date? {
        guard defaults.string(forKey: Self.activityIdKey) == id,
              let seconds = defaults.object(forKey: Self.startedAtKey) as? Double
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private func clearStoredStart() {
        defaults.removeObject(forKey: Self.activityIdKey)
        defaults.removeObject(forKey: Self.startedAtKey)
    }
}

// MARK: - View modifier

extension View {
    /// Keeps the Live Activity in sync with `model` (baby state, sign-in, Settings toggle, foregrounding).
    func benitoLiveActivity(model: AppModel) -> some View {
        modifier(BenitoLiveActivityModifier(model: model))
    }
}

private struct BenitoLiveActivityModifier: ViewModifier {
    var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(LiveActivitySettings.enabledKey) private var enabled = true

    func body(content: Content) -> some View {
        content
            .onAppear { sync() }
            .onChange(of: model.babyState) { sync() }
            .onChange(of: model.isSignedIn) { sync() }
            .onChange(of: enabled) { sync() }
            .onChange(of: scenePhase) {
                if scenePhase == .active { sync() }
            }
    }

    @MainActor
    private func sync() {
        LiveActivityController.shared.sync(
            state: model.babyState,
            childName: model.childName,
            signedIn: model.isSignedIn,
            enabled: enabled
        )
    }
}
