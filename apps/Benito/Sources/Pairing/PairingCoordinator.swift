import BenitoKit
import Foundation
import GroupActivities
import Observation

/// Invite to Family over SharePlay (FaceTime, Messages, or bringing iPhones together).
///
/// 1. Inviter opens Invite to Family; the sheet makes a one-time invite and shares a
///    `PairingActivity` whose `inviteID` is that invite's id.
/// 2. Both phones receive the session. The joiner types their name (no account needed) and
///    sends `.joinRequest`.
/// 3. The inviter confirms and sends `.approvedInvite(url)` to that participant only.
/// 4. The joiner redeems the link like a tapped Messages/AirDrop link (`AppModel.join`) and
///    replies `.joined` or `.failed`.
@MainActor
@Observable
final class PairingCoordinator {
    enum Phase: Equatable {
        case idle
        /// Inviter: session is up; waiting for the other phone to confirm.
        case waitingForPartner
        /// Inviter: someone asked to join; confirm on this phone.
        case confirmPartner(PairingIdentity)
        /// Joiner: confirm joining the inviter's family.
        case confirmJoin(PairingActivity)
        /// Joiner: request sent; waiting for the inviter to confirm.
        case waitingForApproval
        /// Either side: server or messenger round trip in flight.
        case working(String)
        case done(String)
        case failed(String)

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }

        var isFinished: Bool {
            switch self {
            case .idle, .done, .failed: return true
            default: return false
            }
        }
    }

    private(set) var phase: Phase = .idle
    var isSheetPresented = false
    /// True while Invite to Family is on screen; it hosts the session sheet itself because
    /// the root view can't present over another sheet.
    var isHostedByInviteSheet = false
    /// Joiner: name to send; prefilled from the account.
    var joinName = ""
    /// What the inviter's `ShareLink` offers.
    private(set) var outgoingInvite: PartnerInvite?

    /// Owner (`AppModel.pairing`); unowned to avoid a retain cycle.
    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var session: GroupSession<PairingActivity>?
    @ObservationIgnored private var messenger: GroupSessionMessenger?
    @ObservationIgnored private var isInviter = false
    /// Inviter: links by activity id, so a late session for an earlier invite still works.
    @ObservationIgnored private var outgoingLinks: [UUID: FamilyInviteLink] = [:]
    /// Inviter: the participant whose join request is being confirmed.
    @ObservationIgnored private var partner: Participant?
    @ObservationIgnored private var sessionTasks: [Task<Void, Never>] = []

    init(model: AppModel) {
        self.model = model
    }

    /// Invite sheet: offer this invite over SharePlay. Same link, same activity, so the
    /// share sheet and the session always agree on which invite this is.
    func prepareInvite(link: FamilyInviteLink) {
        let id = UUID(uuidString: link.inviteId) ?? UUID()
        if outgoingInvite?.activity.inviteID == id { return }
        let activity = PairingActivity(
            inviteID: id,
            familyName: link.familyName,
            inviterName: link.inviterName,
            serverURL: model.serverURLString
        )
        PairingActivity.markOutgoing(id)
        outgoingLinks[id] = link
        outgoingInvite = PartnerInvite(activity: activity)
    }

    /// Runs for the app's lifetime; SharePlay delivers the session here on both phones.
    func receiveSessions() async {
        for await session in PairingActivity.sessions() {
            begin(session)
        }
    }

    // MARK: - Joiner actions

    func confirmJoin() {
        guard case .confirmJoin = phase else { return }
        let name = joinName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        phase = .waitingForApproval
        send(.joinRequest(PairingIdentity(name: name, email: model.isPasswordless ? "" : model.signedInEmail)))
    }

    // MARK: - Inviter actions

    func approvePartner() {
        guard case .confirmPartner(let identity) = phase, let partner, let messenger,
              let id = session?.activity.inviteID, let link = outgoingLinks[id] else { return }
        guard !link.isExpired else {
            fail("This invite expired. Close and open Invite to Family again.", tellPartner: "The invite expired. Ask for a new one.")
            return
        }
        phase = .working("Adding \(identity.displayName)…")
        Task {
            do {
                try await messenger.send(PairingMessage.approvedInvite(url: link.url.absoluteString), to: .only(partner))
                guard case .working = phase else { return }
                phase = .working("Waiting for \(identity.displayName)'s phone…")
            } catch {
                BenitoLog.ui.error("pairing approve failed: \(String(describing: error), privacy: .public)")
                fail(
                    "Couldn't reach \(identity.displayName)'s phone. Try Messages or AirDrop instead.",
                    tellPartner: "Couldn't receive the invite. Ask them to send it by Messages instead."
                )
            }
        }
    }

    func declinePartner() {
        guard case .confirmPartner = phase else { return }
        send(.declined, to: partner)
        phase = .done("Declined. Nobody was added.")
        endSession()
    }

    /// Cancel / Done, or the sheet was swiped away. Ends the system activity.
    func dismiss() {
        if !phase.isFinished {
            send(.failed(reason: "The other phone cancelled."), to: isInviter ? partner : nil)
        }
        endSession()
        phase = .idle
        isSheetPresented = false
    }

    // MARK: - Session

    private func begin(_ session: GroupSession<PairingActivity>) {
        endSession()
        BenitoLog.ui.notice("pairing session received")
        self.session = session
        let messenger = GroupSessionMessenger(session: session)
        self.messenger = messenger
        isInviter = outgoingLinks[session.activity.inviteID] != nil

        sessionTasks.append(Task { [weak self] in
            for await (message, context) in messenger.messages(of: PairingMessage.self) {
                self?.handle(message, from: context.source)
            }
        })
        sessionTasks.append(Task { [weak self] in
            for await state in session.$state.values {
                if case .invalidated = state {
                    self?.sessionInvalidated()
                    return
                }
            }
        })
        session.join()
        isSheetPresented = true

        if isInviter {
            phase = .waitingForPartner
        } else if model.hasFamily {
            fail(
                "This phone is already part of \(model.familyName). Sign out under Account first to join another family.",
                tellPartner: "Their phone is already part of another family."
            )
        } else {
            if joinName.isEmpty { joinName = model.signedInName }
            phase = .confirmJoin(session.activity)
        }
    }

    private func handle(_ message: PairingMessage, from source: Participant) {
        switch message {
        case .joinRequest(let identity):
            guard isInviter, phase == .waitingForPartner else { return }
            partner = source
            phase = .confirmPartner(identity)
        case .approvedInvite(let urlString):
            guard !isInviter, phase == .waitingForApproval else { return }
            redeem(urlString)
        case .declined:
            guard !isInviter, phase == .waitingForApproval else { return }
            phase = .failed("They declined.")
            endSession()
        case .joined:
            guard isInviter, source == partner, phase.isWorking else { return }
            phase = .done("You're now sharing \(model.familyName).")
            Task { try? await model.refreshSharing() }
        case .failed(let reason):
            guard !phase.isFinished else { return }
            phase = .failed(reason)
            endSession()
        }
    }

    private func redeem(_ urlString: String) {
        guard let url = URL(string: urlString), let link = FamilyInviteLink(url: url) else {
            fail("That invite didn't look right.", tellPartner: "Their phone couldn't read the invite.")
            return
        }
        phase = .working("Joining \(link.familyName)…")
        Task {
            do {
                try await model.join(with: link, name: joinName)
                send(.joined)
                phase = .done("You've joined \(link.familyName).")
            } catch {
                BenitoLog.ui.error("pairing redeem failed: \(String(describing: error), privacy: .public)")
                let reason = error.localizedDescription
                fail("Couldn't join: \(reason)", tellPartner: "Their phone couldn't join: \(reason)")
            }
        }
    }

    private func fail(_ reason: String, tellPartner partnerReason: String) {
        phase = .failed(reason)
        send(.failed(reason: partnerReason), to: isInviter ? partner : nil)
        // join() already started the system activity (Dynamic Island). Failure must end it;
        // dismissing the system peek does not.
        endSession()
    }

    private func sessionInvalidated() {
        BenitoLog.ui.notice("pairing session invalidated")
        if !phase.isFinished {
            phase = .failed("The SharePlay connection ended. Try again, or send the invite by Messages.")
        }
        endSession()
    }

    /// `to: nil` sends to everyone else in the session (the joiner only ever talks to the inviter).
    private func send(_ message: PairingMessage, to participant: Participant? = nil) {
        guard let messenger else { return }
        let recipients: Participants = participant.map { .only($0) } ?? .all
        Task {
            do {
                try await messenger.send(message, to: recipients)
            } catch {
                BenitoLog.ui.error("pairing send failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func endSession() {
        let ending = session
        sessionTasks.forEach { $0.cancel() }
        sessionTasks = []
        session = nil
        messenger = nil
        partner = nil
        isInviter = false
        guard let ending else { return }
        // Invalidated sessions must not be ended or left again.
        if case .invalidated = ending.state { return }
        // end() invalidates the activity for every participant, which is what
        // removes the system SharePlay indicator. leave() drops this phone if
        // end() did not already invalidate the local session.
        ending.end()
        if case .invalidated = ending.state { return }
        ending.leave()
    }
}
