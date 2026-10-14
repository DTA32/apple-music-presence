import Foundation

/// Discord IPC wire format: `opcode: UInt32 LE | length: UInt32 LE | JSON payload`.
public enum IPCOpcode: UInt32, Sendable {
    case handshake = 0
    case frame = 1
    case close = 2
    case ping = 3
    case pong = 4
}

public struct IPCFrame: Sendable, Equatable {
    public var opcode: IPCOpcode
    public var payload: Data

    public init(opcode: IPCOpcode, payload: Data) {
        self.opcode = opcode
        self.payload = payload
    }

    public func encoded() -> Data {
        var data = Data(capacity: 8 + payload.count)
        withUnsafeBytes(of: opcode.rawValue.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    /// Decoded JSON payload, or nil if it isn't a JSON object.
    public var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    }
}

public enum IPCFrameError: Error, Equatable {
    case unknownOpcode(UInt32)
    case frameTooLarge(UInt32)
}

/// Incremental decoder: feed it bytes as they arrive from the socket, get whole frames out.
public struct IPCFrameDecoder: Sendable {
    public static let maxPayload: UInt32 = 1 << 20

    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [IPCFrame] {
        buffer.append(bytes)
        var frames: [IPCFrame] = []
        while buffer.count >= 8 {
            let start = buffer.startIndex
            let rawOpcode = Self.readUInt32(buffer, at: start)
            let length = Self.readUInt32(buffer, at: start + 4)
            guard length <= Self.maxPayload else { throw IPCFrameError.frameTooLarge(length) }
            guard buffer.count >= 8 + Int(length) else { break }
            guard let opcode = IPCOpcode(rawValue: rawOpcode) else { throw IPCFrameError.unknownOpcode(rawOpcode) }
            let payload = Data(buffer[(start + 8)..<(start + 8 + Int(length))])
            frames.append(IPCFrame(opcode: opcode, payload: payload))
            buffer = Data(buffer[(start + 8 + Int(length))...])
        }
        return frames
    }

    private static func readUInt32(_ data: Data, at offset: Data.Index) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(data[offset + i]) << (8 * UInt32(i))
        }
        return value
    }
}
