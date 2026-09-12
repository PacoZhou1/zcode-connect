import Foundation

/// Tag 5 keeps its original JSON bytes, including member order, for exact golden-vector round trips.
public indirect enum RelayIPCValue: Sendable, Equatable {
    case undefined, string(String), bytes(Data), vsBuffer(Data), array([RelayIPCValue]), int32(Int32), json(Data)

    public static func object(_ value: RelayJSON) throws -> Self { .json(try value.data()) }
    public func jsonValue() throws -> RelayJSON {
        switch self {
        case .undefined: return .null
        case .string(let v): return .string(v)
        case .int32(let v): return .number(Double(v))
        case .array(let v): return .array(try v.map { try $0.jsonValue() })
        case .json(let v): return try RelayJSON(data: v)
        case .bytes(let v), .vsBuffer(let v): return .object(["__zcode_rpc_nested_uint8array_v1": .bool(true), "base64": .string(v.base64EncodedString())])
        }
    }
}

public struct RelayIPCMessage: Sendable, Equatable {
    public let header: [RelayIPCValue]
    public let body: RelayIPCValue
    public init(header: [RelayIPCValue], body: RelayIPCValue) { self.header = header; self.body = body }
    public var type: Int32? { if case .int32(let v) = header.first { v } else { nil } }
    public var requestID: Int32? { guard header.count > 1 else { return nil }; if case .int32(let v) = header[1] { return v }; return nil }
}

public enum RelayIPCCodec {
    public static func encode(_ message: RelayIPCMessage) throws -> Data {
        var output = Data()
        try append(.array(message.header), to: &output, depth: 0)
        try append(message.body, to: &output, depth: 0)
        guard output.count <= RelayWire.maxMessage else { throw RelayFailure.invalid("IPC exceeds 16 MiB.") }; return output
    }
    private static func appendVarint(_ value: UInt32, to output: inout Data) {
        var n = value
        repeat { let next = n >> 7; output.append(UInt8(n & 127) | (next == 0 ? 0 : 128)); n = next } while n != 0
    }
    private static func append(_ value: RelayIPCValue, to output: inout Data, depth: Int) throws {
        guard depth <= 100, output.count <= RelayWire.maxMessage else { throw RelayFailure.invalid("IPC nesting or size limit exceeded.") }
        func blob(_ tag: UInt8, _ data: Data) throws {
            guard data.count <= RelayWire.maxMessage, output.count + data.count + 6 <= RelayWire.maxMessage else { throw RelayFailure.invalid("IPC value is too large.") }
            output.append(tag); appendVarint(UInt32(data.count), to: &output); output.append(data)
        }
        switch value {
        case .undefined: output.append(0)
        case .string(let v): try blob(1, Data(v.utf8))
        case .bytes(let v): try blob(2, v)
        case .vsBuffer(let v): try blob(3, v)
        case .json(let v):
            guard String(data: v, encoding: .utf8) != nil else { throw RelayFailure.invalid("Invalid JSON UTF-8.") }
            _ = try RelayJSON(data: v); try blob(5, v)
        case .array(let values):
            guard values.count <= 100_000 else { throw RelayFailure.invalid("IPC array is too large.") }
            output.append(4); appendVarint(UInt32(values.count), to: &output)
            for v in values { try append(v, to: &output, depth: depth + 1) }
        case .int32(let v): output.append(6); appendVarint(UInt32(bitPattern: v), to: &output)
        }
    }
    public static func decode(_ data: Data) throws -> RelayIPCMessage {
        guard data.count <= RelayWire.maxMessage else { throw RelayFailure.invalid("IPC exceeds 16 MiB.") }
        var reader = Reader(bytes: Array(data))
        let header = try reader.value(depth: 0), body = try reader.value(depth: 0)
        guard reader.offset == data.count, case .array(let fields) = header, !fields.isEmpty else { throw RelayFailure.invalid("Invalid IPC envelope.") }
        return RelayIPCMessage(header: fields, body: body)
    }
    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw RelayFailure.invalid("Truncated IPC.") }; defer { offset += 1 }; return bytes[offset]
        }
        mutating func integer() throws -> UInt32 {
            var value: UInt32 = 0
            for i in 0..<5 {
                let b = try byte()
                guard i != 4 || b <= 15 else { throw RelayFailure.invalid("IPC varint overflow.") }
                value |= UInt32(b & 127) << (7 * i)
                if b & 128 == 0 {
                    guard i == 0 || b != 0 else { throw RelayFailure.invalid("Noncanonical IPC varint.") }; return value
                }
            }
            throw RelayFailure.invalid("Invalid IPC varint.")
        }
        mutating func value(depth: Int) throws -> RelayIPCValue {
            guard depth <= 100 else { throw RelayFailure.invalid("IPC nesting limit exceeded.") }
            let tag = try byte()
            if tag == 0 { return .undefined }
            if tag == 6 { return .int32(Int32(bitPattern: try integer())) }
            guard (1...5).contains(tag) else { throw RelayFailure.invalid("Unknown IPC tag.") }
            let length = Int(try integer())
            guard length <= RelayWire.maxMessage else { throw RelayFailure.invalid("Invalid IPC length.") }
            if tag == 4 {
                guard length <= 100_000, length <= bytes.count - offset else { throw RelayFailure.invalid("Invalid IPC array length.") }
                var values: [RelayIPCValue] = []; values.reserveCapacity(length)
                for _ in 0..<length { values.append(try value(depth: depth + 1)) }; return .array(values)
            }
            guard length <= bytes.count - offset else { throw RelayFailure.invalid("Truncated IPC payload.") }
            let payload = Data(bytes[offset..<(offset + length)]); offset += length
            if tag == 2 { return .bytes(payload) }; if tag == 3 { return .vsBuffer(payload) }
            guard let text = String(data: payload, encoding: .utf8) else { throw RelayFailure.invalid("Invalid IPC UTF-8.") }
            if tag == 1 { return .string(text) }
            _ = try RelayJSON(data: payload); return .json(payload)
        }
    }
}

public enum RelayChecksum {
    public static func crc32(_ bytes: Data) -> String {
        var value: UInt32 = 0xffff_ffff
        for byte in bytes {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xedb8_8320 : 0) }
        }
        return String(format: "%08x", value ^ 0xffff_ffff)
    }
}
