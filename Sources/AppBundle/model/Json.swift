import AppKit
import Common

enum Json: Encodable, Equatable {
    // vector
    case dict([String: Json])
    case array([Json])

    // scalar
    case null
    case string(String)
    case int(Int)
    case uint32(UInt32)
    case bool(Bool)

    func encode(to encoder: any Encoder) throws {
        switch self {
            case .array(let value): try value.encode(to: encoder)
            case .dict(let value): try value.encode(to: encoder)
            case .string(let value): try value.encode(to: encoder)
            case .int(let value): try value.encode(to: encoder)
            case .uint32(let value): try value.encode(to: encoder)
            case .bool(let value): try value.encode(to: encoder)
            case .null: try (nil as String?).encode(to: encoder)
        }
    }

    static func stringOrNull(_ str: String?) -> Json { str.map(Json.string) ?? .null }
}
