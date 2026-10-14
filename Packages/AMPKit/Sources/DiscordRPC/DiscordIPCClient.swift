import Foundation
import os

/// Talks to the local Discord desktop client over its IPC socket and keeps the presence in sync.
///
/// Callers just say what the activity *should* be (`setActivity`); the client handles connecting,
/// reconnecting with backoff, rate limiting, and re-sending the latest state after a reconnect.
public actor DiscordIPCClient {
    public enum Status: Sendable, Equatable {
        case stopped
        case notConfigured
        case waitingForDiscord
        case connected(username: String?)
        case error(String)
    }

    public nonisolated let statusUpdates: AsyncStream<Status>
    private let statusContinuation: AsyncStream<Status>.Continuation

    private let log = Logger(subsystem: "dev.dta32.applemusicpresence", category: "discord")
    private let pid = ProcessInfo.processInfo.processIdentifier

    private var clientID = ""
    private var socket: UnixSocket?
    private var readerTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<String?, any Error>?
    private var earlyReady: Result<String?, any Error>?
    private var isReady = false
    private var isRunning = false
    private var backoff: TimeInterval = DiscordIPCClient.minBackoff
    private var throttle = SendThrottle()

    /// The activity we want Discord to show; `nil` = clear.
    private var desired: Activity?
    /// JSON of the last activity Discord accepted from us; avoids redundant sends.
    private var lastSentJSON: Data?

    private static let minBackoff: TimeInterval = 5
    private static let maxBackoff: TimeInterval = 60

    public private(set) var status: Status = .stopped {
        didSet { if status != oldValue { statusContinuation.yield(status) } }
    }

    public init() {
        (statusUpdates, statusContinuation) = AsyncStream.makeStream(of: Status.self, bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: - Public API

    /// Starts (or restarts with a different client ID) the connect loop.
    public func start(clientID: String) {
        let trimmed = clientID.trimmingCharacters(in: .whitespaces)
        if isRunning && trimmed == self.clientID { return }
        disconnect()
        self.clientID = trimmed
        guard !trimmed.isEmpty else {
            isRunning = false
            status = .notConfigured
            return
        }
        isRunning = true
        backoff = Self.minBackoff
        scheduleConnect(after: 0)
    }

    /// Disconnects; Discord removes our presence when the socket closes.
    public func stop() {
        isRunning = false
        disconnect()
        status = .stopped
    }

    public func setActivity(_ activity: Activity?) {
        desired = activity?.sanitized()
        flushIfNeeded()
    }

    /// Skip the backoff wait, e.g. right after Discord launches.
    public func reconnectNow() {
        guard isRunning, socket == nil else { return }
        backoff = Self.minBackoff
        scheduleConnect(after: 0)
    }

    // MARK: - Connection

    private func scheduleConnect(after delay: TimeInterval) {
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.attemptConnect()
        }
    }

    private func attemptConnect() async {
        guard isRunning, socket == nil else { return }
        guard let path = Self.candidateSocketPaths().first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            status = .waitingForDiscord
            retryLater()
            return
        }

        do {
            let socket = try UnixSocket.connect(path: path)
            self.socket = socket
            readerTask = Task { [weak self] in
                for await event in socket.events {
                    await self?.handle(event, from: socket)
                }
            }
            try send(.handshake, json: ["v": 1, "client_id": clientID])
            let username = try await waitForReady(timeout: 5)
            isReady = true
            backoff = Self.minBackoff
            throttle.reset()
            lastSentJSON = nil
            status = .connected(username: username)
            log.info("Connected to Discord at \(path, privacy: .public)")
            flushIfNeeded()
        } catch {
            log.error("Discord connect failed: \(String(describing: error), privacy: .public)")
            disconnect()
            if case .error = status {} else { status = .waitingForDiscord }
            retryLater()
        }
    }

    private func waitForReady(timeout: TimeInterval) async throws -> String? {
        if let early = earlyReady {
            earlyReady = nil
            return try early.get()
        }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.resolveReady(.failure(DiscordIPCError.timeout))
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
        }
    }

    /// Resolves the pending handshake wait, or remembers the result if nobody is waiting yet.
    private func resolveReady(_ result: Result<String?, any Error>) {
        if let continuation = readyContinuation {
            readyContinuation = nil
            continuation.resume(with: result)
        } else if socket != nil, !isReady {
            earlyReady = result
        }
    }

    private func retryLater() {
        guard isRunning else { return }
        let delay = backoff
        backoff = min(backoff * 2, Self.maxBackoff)
        scheduleConnect(after: delay)
    }

    private func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        sendTask?.cancel()
        sendTask = nil
        readerTask?.cancel()
        readerTask = nil
        socket?.shutdown()
        socket = nil
        isReady = false
        lastSentJSON = nil
        throttle.reset()
        earlyReady = nil
        let continuation = readyContinuation
        readyContinuation = nil
        continuation?.resume(throwing: DiscordIPCError.disconnected)
    }

    private func handle(_ event: UnixSocket.Event, from source: UnixSocket) {
        guard source === socket else { return }
        switch event {
        case .frame(let frame):
            handle(frame)
        case .closed(let reason):
            log.info("Discord socket closed: \(reason ?? "EOF", privacy: .public)")
            disconnect()
            if case .error = status {} else { status = .waitingForDiscord }
            retryLater()
        }
    }

    private func handle(_ frame: IPCFrame) {
        switch frame.opcode {
        case .frame:
            guard let json = frame.json else { return }
            let event = json["evt"] as? String
            if event == "READY" {
                let user = (json["data"] as? [String: Any])?["user"] as? [String: Any]
                let name = (user?["global_name"] as? String) ?? (user?["username"] as? String)
                resolveReady(.success(name))
            } else if event == "ERROR" {
                let message = (json["data"] as? [String: Any])?["message"] as? String ?? "Unknown error"
                log.error("Discord rejected \(json["cmd"] as? String ?? "?", privacy: .public): \(message, privacy: .public)")
                // A rejected activity must not be treated as sent, or we'd never retry it.
                lastSentJSON = nil
            }
        case .ping:
            try? socket?.send(IPCFrame(opcode: .pong, payload: frame.payload))
        case .close:
            let json = frame.json
            let message = json?["message"] as? String ?? "Discord closed the connection"
            let code = json?["code"] as? Int
            log.error("Discord closed IPC: \(code ?? -1) \(message, privacy: .public)")
            status = .error(code.map { "\(message) (\($0))" } ?? message)
            resolveReady(.failure(DiscordIPCError.closed(message)))
        case .handshake, .pong:
            break
        }
    }

    // MARK: - Sending

    private func flushIfNeeded() {
        guard isReady, sendTask == nil else { return }
        guard let json = try? encodedActivity(desired), json != lastSentJSON else { return }
        switch throttle.request(at: Date()) {
        case .sendNow:
            sendDesired()
        case .sendAfter(let wait):
            sendTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                await self?.trailingSend()
            }
        case .alreadyScheduled:
            break
        }
    }

    private func trailingSend() {
        sendTask = nil
        sendDesired()
    }

    private func sendDesired() {
        guard isReady, let json = try? encodedActivity(desired), json != lastSentJSON else {
            throttle.didSend(at: Date())
            return
        }
        do {
            let command = SetActivityCommand(args: .init(pid: pid, activity: desired), nonce: UUID().uuidString)
            try socket?.send(IPCFrame(opcode: .frame, payload: JSONEncoder().encode(command)))
            lastSentJSON = json
            throttle.didSend(at: Date())
        } catch {
            log.error("SET_ACTIVITY write failed: \(String(describing: error), privacy: .public)")
            disconnect()
            status = .waitingForDiscord
            retryLater()
        }
    }

    private func encodedActivity(_ activity: Activity?) throws -> Data {
        guard let activity else { return Data("null".utf8) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(activity)
    }

    private func send(_ opcode: IPCOpcode, json: [String: Any]) throws {
        guard let socket else { throw DiscordIPCError.disconnected }
        try socket.send(IPCFrame(opcode: opcode, payload: JSONSerialization.data(withJSONObject: json)))
    }

    // MARK: - Socket discovery

    /// Discord listens on `discord-ipc-0` … `discord-ipc-9` in the per-user temp directory.
    nonisolated static func candidateSocketPaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var directories: [String] = []
        for key in ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"] {
            if let value = environment[key], !value.isEmpty { directories.append(value) }
        }
        directories.append(NSTemporaryDirectory())
        directories.append("/tmp")
        var seen = Set<String>()
        let unique = directories
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .filter { seen.insert($0).inserted }
        return unique.flatMap { dir in (0...9).map { "\(dir)/discord-ipc-\($0)" } }
    }
}

public enum DiscordIPCError: Error, Equatable {
    case timeout
    case disconnected
    case closed(String)
}

struct SetActivityCommand: Encodable {
    struct Args: Encodable {
        var pid: Int32
        /// Omitted when nil, which clears the activity.
        var activity: Activity?
    }

    var cmd = "SET_ACTIVITY"
    var args: Args
    var nonce: String
}
