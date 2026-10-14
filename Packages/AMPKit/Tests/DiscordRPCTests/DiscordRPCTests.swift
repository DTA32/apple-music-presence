@testable import DiscordRPC
import Foundation
import Testing

@Suite struct IPCFrameTests {
    @Test func encodeLayoutIsLittleEndian() {
        let frame = IPCFrame(opcode: .frame, payload: Data("{}".utf8))
        #expect(Array(frame.encoded()) == [1, 0, 0, 0, 2, 0, 0, 0, 0x7B, 0x7D])
    }

    @Test func decoderHandlesSplitAndCoalescedReads() throws {
        let a = IPCFrame(opcode: .frame, payload: Data(#"{"evt":"READY"}"#.utf8))
        let b = IPCFrame(opcode: .ping, payload: Data("{}".utf8))
        let bytes = a.encoded() + b.encoded()
        var decoder = IPCFrameDecoder()
        let aLength = a.encoded().count
        #expect(try decoder.append(bytes.prefix(5)).isEmpty)             // header split
        #expect(try decoder.append(bytes[5..<aLength]) == [a])
        #expect(try decoder.append(bytes[aLength...]) == [b])
        // Two frames in one read.
        var fresh = IPCFrameDecoder()
        #expect(try fresh.append(bytes) == [a, b])
    }

    @Test func decoderRejectsGarbage() {
        var decoder = IPCFrameDecoder()
        #expect(throws: IPCFrameError.unknownOpcode(9)) {
            try decoder.append(IPCFrame(opcode: .frame, payload: Data()).encoded().replacing([1], with: [9], maxReplacements: 1))
        }
    }
}

@Suite struct ActivityTests {
    @Test func encodesSnakeCaseAndOmitsNil() throws {
        let activity = Activity(type: 2, statusDisplayType: 1, details: "Song", assets: .init(largeImage: "logo"))
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(activity)) as? [String: Any])
        #expect(json["status_display_type"] as? Int == 1)
        #expect((json["assets"] as? [String: Any])?["large_image"] as? String == "logo")
        #expect(json["state"] == nil)
        #expect(json["buttons"] == nil)
    }

    @Test func sanitizeClampsText() {
        let long = String(repeating: "x", count: 300)
        let activity = Activity(details: long, state: "A", assets: .init(largeText: "  "))
            .sanitized()
        #expect(activity.details?.count == 128)
        #expect(activity.details?.hasSuffix("…") == true)
        #expect(activity.state?.count == 2) // padded
        #expect(activity.assets?.largeText == nil)
    }

    @Test func sanitizeDropsBadButtons() {
        let activity = Activity(buttons: [
            .init(label: "", url: "https://a.example"),
            .init(label: "Not a URL", url: "music://x"),
            .init(label: String(repeating: "L", count: 40), url: "https://b.example"),
            .init(label: "Two", url: "https://c.example"),
            .init(label: "Three", url: "https://d.example"),
        ]).sanitized()
        #expect(activity.buttons?.count == 2)
        #expect(activity.buttons?.first?.label.count == 32)
    }

    @Test func clearCommandOmitsActivity() throws {
        let command = SetActivityCommand(args: .init(pid: 42, activity: nil), nonce: "n")
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any])
        let args = try #require(json["args"] as? [String: Any])
        #expect(args["pid"] as? Int == 42)
        #expect(args["activity"] == nil)
        #expect(json["cmd"] as? String == "SET_ACTIVITY")
    }
}

@Suite struct SendThrottleTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func leadingThenTrailing() {
        var throttle = SendThrottle(interval: 4)
        #expect(throttle.request(at: t0) == .sendNow)
        throttle.didSend(at: t0)
        #expect(throttle.request(at: t0.addingTimeInterval(1)) == .sendAfter(3))
        #expect(throttle.request(at: t0.addingTimeInterval(2)) == .alreadyScheduled)
        throttle.didSend(at: t0.addingTimeInterval(4))
        #expect(throttle.request(at: t0.addingTimeInterval(9)) == .sendNow)
    }

    @Test func burstStaysWithinDiscordLimit() {
        // 5 updates per 20 s allowed; a skip-storm of 50 requests over 20 s must send ≤ 5.
        var throttle = SendThrottle(interval: 4)
        var sends: [Date] = []
        var pendingAt: Date?
        for i in 0..<50 {
            let now = t0.addingTimeInterval(Double(i) * 0.4)
            if let due = pendingAt, due <= now {
                throttle.didSend(at: due)
                sends.append(due)
                pendingAt = nil
            }
            switch throttle.request(at: now) {
            case .sendNow:
                throttle.didSend(at: now)
                sends.append(now)
            case .sendAfter(let wait):
                pendingAt = now.addingTimeInterval(wait)
            case .alreadyScheduled:
                break
            }
        }
        #expect(sends.count <= 5)
        for (a, b) in zip(sends, sends.dropFirst()) {
            #expect(b.timeIntervalSince(a) >= 4 - 1e-9)
        }
    }
}

@Suite struct SocketDiscoveryTests {
    @Test func tmpdirFirstNoDuplicates() {
        let paths = DiscordIPCClient.candidateSocketPaths(environment: ["TMPDIR": "/var/folders/x/T/"])
        #expect(paths.first == "/var/folders/x/T/discord-ipc-0")
        #expect(paths.contains("/tmp/discord-ipc-9"))
        #expect(Set(paths).count == paths.count)
    }
}
