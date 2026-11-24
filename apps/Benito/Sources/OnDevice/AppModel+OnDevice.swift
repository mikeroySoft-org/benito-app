import BenitoKit
import Foundation

// MARK: - On-device mode: no server, no account

extension AppModel {
    /// Answers data calls: this phone in on-device mode, otherwise the family server.
    func service() throws -> any BenitoService {
        if isOnDevice { return localService }
        return try client()
    }

    /// First run with "This iPhone only": the local family and baby, then the home screen.
    func startOnDevice(yourName: String, familyName: String, childName: String) async throws {
        // Already set up here (setup submitted twice): nothing to tear down or create.
        if isOnDevice, isSignedIn { return }
        if isSignedIn { tearDownSession() }
        do {
            _ = try await localService.createProfile(yourName: yourName, familyName: familyName, childName: childName)
        } catch {
            throw SharingError.failed(Self.message(for: error))
        }
        BenitoMode.set(.onDevice)
        isOnDevice = true
        await restoreOnDevice()
    }

    /// Launch in on-device mode: same path as a server session (`/me`, state, Day summary),
    /// answered by `localService`. Nothing here opens a network connection.
    func restoreOnDevice() async {
        guard (try? await LocalProfile.load(from: store)) != nil else {
            // Mode flag without a profile (e.g. setup interrupted): back to onboarding.
            BenitoMode.set(.server)
            isOnDevice = false
            return
        }
        isSignedIn = true
        status = String(localized: "On this \(BenitoDevice.name)")
        await refreshMe()
    }

    /// Siri, Live Activity and widget buttons change the store directly in on-device mode.
    func observeLocalStoreChanges() {
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .benitoLocalStoreDidChange) {
                guard let self, self.isOnDevice else { continue }
                await self.refreshState()
            }
        }
    }

    /// A move to a server that stopped partway (app closed, connection dropped).
    var pendingServerMove: PendingServerMigration? { PendingServerMigration.load() }

    /// Account › Erase all data: deletes the local family, baby and every entry, forgets any
    /// move to a server in progress, and returns to first-run onboarding.
    func eraseOnDeviceData() async {
        guard isOnDevice else { return }
        BenitoLog.ui.notice("eraseOnDeviceData")
        do {
            try await store.eraseAll()
        } catch {
            BenitoLog.ui.error("eraseOnDeviceData failed: \(String(describing: error), privacy: .public)")
            status = "Erase failed: \(Self.message(for: error))"
            return
        }
        // A move that had started signed this phone in to that server; drop that sign-in too.
        if let server = (pendingServerMove?.serverURL).flatMap(URL.init(string:)) {
            try? tokenStore.deleteToken(for: server)
            storeDeviceId(nil, for: server)
        }
        PendingServerMigration.clear()
        serverMove = nil
        BenitoMode.set(.server)
        isOnDevice = false
        tearDownSession()
        clearFamilyState()
        outboxPending = 0
        status = "Not signed in"
    }
}

// MARK: - Account › Connect to a server

extension AppModel {
    /// Copies this phone's history to `server` and switches the app to it.
    ///
    /// Safe to run again after any failure: the target family is remembered once it exists,
    /// each entry keeps its id (the server stores it once), and uploaded entries leave the
    /// on-device list, so a retry carries on with what is left.
    func connectToServer(_ requested: URL) async throws {
        guard isOnDevice else { return }
        guard babyState?.activeTimer == nil else {
            throw SharingError.failed(String(localized: "Stop the running timer first, then connect."))
        }
        var pending = PendingServerMigration.load()
        if pending?.serverChildId == nil, pending?.serverURL != requested.absoluteString {
            pending = nil // nothing created yet on the old choice; start over with this one
        }
        guard let localChildId = pending?.localChildId ?? childId else {
            throw SharingError.failed(String(localized: "Nothing to move yet."))
        }
        let server = pending.flatMap { URL(string: $0.serverURL) } ?? requested
        var move = pending ?? PendingServerMigration(serverURL: server.absoluteString, localChildId: localChildId)
        move.save()
        serverMove = ServerMoveProgress(server: server, phase: .connecting)
        defer { serverMove = nil }

        guard let info = await Self.probe(server) else {
            throw SharingError.failed(String(localized: "Can't reach that server. Check the address and that this \(BenitoDevice.name) is on the same network."))
        }
        let client = try await serverSession(at: server)

        // The family to move into: created once, then remembered.
        if move.serverChildId == nil {
            do {
                let me = try await client.me()
                if me.family != nil, let first = me.children.first {
                    move.serverChildId = first.id
                } else {
                    let created = try await client.createFamily(name: familyName, childName: childName)
                    move.serverChildId = created.child.id
                }
            } catch {
                throw SharingError.failed(Self.message(for: error))
            }
            move.save()
        }
        guard let serverChildId = move.serverChildId else { return }

        do {
            try await LocalToServerUploader(store: store, server: client).upload(
                localChildId: localChildId,
                serverChildId: serverChildId
            ) { [weak self] progress in
                await MainActor.run {
                    self?.serverMove?.phase = .uploading(done: progress.uploaded, total: progress.total)
                }
            }
        } catch {
            throw SharingError.failed(Self.message(for: error))
        }

        serverMove?.phase = .finishing
        rememberEndpoints([server] + info.advertisedUrls.compactMap(URL.init(string:)), serverId: info.serverId)
        try? await LocalProfile.clear(from: store)
        PendingServerMigration.clear()
        BenitoMode.set(.server)
        isOnDevice = false
        isSignedIn = false
        await switchServer(to: server)
        await restoreSession()
    }

    /// A signed-in client for `server`: the saved session, this phone's key, or a new
    /// passwordless account named like the on-device parent.
    private func serverSession(at server: URL) async throws -> APIClient {
        if let token = try? tokenStore.token(for: server) {
            return APIClient(baseURL: server, token: token, clientId: clientId)
        }
        let anonymous = APIClient(baseURL: server, clientId: clientId)
        do {
            let res: DeviceAuthResponseDTO
            if let deviceId = storedDeviceId(for: server) {
                res = try await anonymous.deviceSession(deviceId: deviceId, identity: deviceIdentity)
            } else {
                res = try await anonymous.deviceSignup(
                    name: signedInName.isEmpty ? String(localized: "Parent") : signedInName,
                    identity: deviceIdentity,
                    deviceName: Self.deviceName,
                    model: Self.deviceModel
                )
            }
            try tokenStore.setToken(res.token, for: server)
            storeDeviceId(res.deviceId, for: server)
            return APIClient(baseURL: server, token: res.token, clientId: clientId)
        } catch {
            if case .httpStatus(404, _)? = error as? APIClientError { throw SharingError.unsupportedServer }
            throw SharingError.failed(Self.message(for: error))
        }
    }
}
