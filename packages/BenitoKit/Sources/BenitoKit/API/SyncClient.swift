import Foundation
import OSLog

public enum SyncClientError: Error, Sendable {
    case notConnected
    case invalidURL
    case transport(String)
}

/// WebSocket client for `WS /sync`. Auth via first message; parses envelopes.
/// Reconnects with exponential backoff when the socket drops unexpectedly.
public final class SyncClient: @unchecked Sendable {
    public private(set) var isConnected = false

    private var token: String
    private let clientId: String
    private let syncURL: URL
    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private let onEnvelope: @Sendable (SyncEnvelopeDTO) -> Void
    private let onDisconnect: @Sendable (String?) -> Void
    private let onReconnect: @Sendable () -> Void

    private var wantsConnection = false
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private let lock = NSLock()
    private let maxBackoffSeconds: Double = 30

    public init(
        serverBaseURL: URL,
        token: String,
        clientId: String = UUID().uuidString,
        session: URLSession = .shared,
        onEnvelope: @escaping @Sendable (SyncEnvelopeDTO) -> Void,
        onDisconnect: @escaping @Sendable (String?) -> Void = { _ in },
        onReconnect: @escaping @Sendable () -> Void = {}
    ) {
        self.token = token
        self.clientId = clientId
        self.session = session
        self.onEnvelope = onEnvelope
        self.onDisconnect = onDisconnect
        self.onReconnect = onReconnect
        self.syncURL = Self.makeSyncURL(from: serverBaseURL)
    }

    private static func makeSyncURL(from base: URL) -> URL {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        let scheme = (comps.scheme?.lowercased() == "https") ? "wss" : "ws"
        comps.scheme = scheme
        comps.path = "/sync"
        comps.query = nil
        comps.fragment = nil
        return comps.url ?? base.appendingPathComponent("sync")
    }

    public func updateToken(_ token: String) {
        self.token = token
    }

    public func connect() {
        BenitoLog.sync.notice("connect \(self.syncURL.absoluteString, privacy: .public)")
        lock.lock()
        wantsConnection = true
        reconnectAttempt = 0
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        lock.unlock()
        openSocket(isReconnect: false)
    }

    public func disconnect() {
        BenitoLog.sync.notice("disconnect")
        lock.lock()
        wantsConnection = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        lock.unlock()
        isConnected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    public func sendPing() {
        sendJSON(["type": "ping"])
    }

    private func openSocket(isReconnect: Bool) {
        task?.cancel(with: .goingAway, reason: nil)
        let task = session.webSocketTask(with: syncURL)
        self.task = task
        task.resume()
        isConnected = true
        if isReconnect {
            BenitoLog.sync.notice("reconnected")
            onReconnect()
        }
        sendAuth()
        receiveLoop()
    }

    private func sendAuth() {
        sendJSON([
            "type": "auth",
            "payload": [
                "token": token,
                "client_id": clientId,
            ],
        ])
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task?.send(.string(text)) { [weak self] error in
            if let error {
                self?.handleDrop(reason: error.localizedDescription)
            }
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.handleDrop(reason: error.localizedDescription)
            case .success(let message):
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8),
                       let envelope = try? BenitoJSON.decoder.decode(SyncEnvelopeDTO.self, from: data)
                    {
                        BenitoLog.sync.debug("envelope \(envelope.type, privacy: .public)")
                        self.onEnvelope(envelope)
                    }
                case .data(let data):
                    if let envelope = try? BenitoJSON.decoder.decode(SyncEnvelopeDTO.self, from: data) {
                        BenitoLog.sync.debug("envelope \(envelope.type, privacy: .public)")
                        self.onEnvelope(envelope)
                    }
                @unknown default:
                    break
                }
                if self.isConnected {
                    self.receiveLoop()
                }
            }
        }
    }

    private func handleDrop(reason: String?) {
        BenitoLog.sync.warning("drop: \(reason ?? "nil", privacy: .public)")
        isConnected = false
        onDisconnect(reason)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        lock.lock()
        defer { lock.unlock() }
        guard wantsConnection else { return }
        reconnectWorkItem?.cancel()
        let attempt = reconnectAttempt
        reconnectAttempt = min(reconnectAttempt + 1, 10)
        let delay = min(pow(2.0, Double(attempt)), maxBackoffSeconds)
        BenitoLog.sync.notice("schedule reconnect attempt=\(attempt, privacy: .public) delay=\(delay, privacy: .public)s")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillWanted = self.wantsConnection
            self.lock.unlock()
            guard stillWanted else { return }
            self.openSocket(isReconnect: true)
        }
        reconnectWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }
}
