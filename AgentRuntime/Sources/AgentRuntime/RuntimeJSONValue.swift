import Foundation

public enum RuntimeJSONValue: Sendable, Hashable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: RuntimeJSONValue])
    case array([RuntimeJSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let object = try? container.decode([String: RuntimeJSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([RuntimeJSONValue].self) {
            self = .array(array)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let string):
            try container.encode(string)
        case .int(let int):
            try container.encode(int)
        case .double(let double):
            try container.encode(double)
        case .bool(let bool):
            try container.encode(bool)
        case .object(let object):
            try container.encode(object)
        case .array(let array):
            try container.encode(array)
        case .null:
            try container.encodeNil()
        }
    }
}

// 字面量支持。JSON Schema 手写起来层数很深,没有字面量的话每一层都要 `.string(…)`,
// 读的人根本看不出那本来是一段 JSON。
extension RuntimeJSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension RuntimeJSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension RuntimeJSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension RuntimeJSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension RuntimeJSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension RuntimeJSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: RuntimeJSONValue...) { self = .array(elements) }
}

extension RuntimeJSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, RuntimeJSONValue)...) {
        self = .object(Dictionary(elements) { _, latest in latest })
    }
}

public extension RuntimeJSONValue {
    init(_ string: String) { self = .string(string) }
    init(_ int: Int) { self = .int(int) }
    init(_ double: Double) { self = .double(double) }
    init(_ bool: Bool) { self = .bool(bool) }
    init(_ array: [RuntimeJSONValue]) { self = .array(array) }
    init(_ object: [String: RuntimeJSONValue]) { self = .object(object) }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(exactly: value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var objectValue: [String: RuntimeJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [RuntimeJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> RuntimeJSONValue? {
        objectValue?[key]
    }

    subscript(index: Int) -> RuntimeJSONValue? {
        guard let arrayValue, arrayValue.indices.contains(index) else { return nil }
        return arrayValue[index]
    }

    static func decode(from string: String) throws -> RuntimeJSONValue {
        let decoder = JSONDecoder()
        return try decoder.decode(RuntimeJSONValue.self, from: Data(string.utf8))
    }

    func encodedString(prettyPrinted: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
