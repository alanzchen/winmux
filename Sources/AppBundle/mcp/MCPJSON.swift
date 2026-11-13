import Foundation

/// A JSON value as MCP's JSON-RPC messages carry it, read and written whole.
enum MCPJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([MCPJSON])
    case object([String: MCPJSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([MCPJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: MCPJSON].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
            case .null: try container.encodeNil()
            case .bool(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            case .double(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> MCPJSON? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var array: [MCPJSON]? { if case .array(let value) = self { value } else { nil } }
    var object: [String: MCPJSON]? { if case .object(let value) = self { value } else { nil } }

    static func decode(_ data: Data) -> MCPJSON? { try? JSONDecoder().decode(MCPJSON.self, from: data) }

    /// Sorted keys, so the same value is always written the same way.
    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }
}
