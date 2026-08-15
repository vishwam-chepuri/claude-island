import Foundation

/// An untyped JSON tree.
///
/// Hook payloads carry `tool_input`, whose shape is different for every tool and
/// changes whenever Claude Code gains a new one. Decoding it into per-tool
/// structs would mean a decode failure — and a blank HUD — the first time an
/// unfamiliar tool appears. Keeping it as a tree makes `Bash.command`,
/// `Edit.file_path` and `WebFetch.url` ordinary key lookups that simply return
/// nil when absent.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "unrepresentable JSON value")
        }
    }
}

extension JSONValue: Encodable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        guard case .object(let o) = self else { return nil }
        return o[key]
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        if case .number(let n) = self { return Int(n) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// First non-empty string found at any of `keys`, in order.
    public func firstString(_ keys: [String]) -> String? {
        for k in keys {
            if let s = self[k]?.stringValue, !s.isEmpty { return s }
        }
        return nil
    }
}
