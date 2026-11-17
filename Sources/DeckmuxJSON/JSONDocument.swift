import Foundation

/// A JSON value that keeps object key order and the exact text of numbers,
/// so Deckmux can change one key of a file it does not own (Claude Code's
/// settings, `~/.claude.json`) and write everything else back untouched.
public indirect enum JSONValue: Equatable {
    case object([(key: String, value: JSONValue)])
    case array([JSONValue])
    case string(String)
    /// The number as written in the file.
    case number(String)
    case bool(Bool)
    case null

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.object(let a), .object(let b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case (.array(let a), .array(let b)): a == b
        case (.string(let a), .string(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.bool(let a), .bool(let b)): a == b
        case (.null, .null): true
        default: false
        }
    }

    // MARK: Reading

    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectMembers: [(key: String, value: JSONValue)]? {
        if case .object(let value) = self { return value }
        return nil
    }

    // MARK: Changing

    /// Sets `key`, keeping its position when it exists and appending it
    /// otherwise. `nil` removes the key. Only valid on objects.
    public mutating func set(_ key: String, _ value: JSONValue?) {
        guard case .object(var members) = self else { return }
        if let index = members.firstIndex(where: { $0.key == key }) {
            if let value { members[index].value = value } else { members.remove(at: index) }
        } else if let value {
            members.append((key, value))
        }
        self = .object(members)
    }

    /// Changes the value at `path` (object keys), creating missing objects on
    /// the way. Returning nil from `change` removes the key.
    public mutating func update(_ path: [String], _ change: (JSONValue?) -> JSONValue?) {
        guard let key = path.first else {
            self = change(self) ?? .null
            return
        }
        if case .object = self {} else { self = .object([]) }
        if path.count == 1 {
            set(key, change(self[key]))
            return
        }
        var child = self[key] ?? .object([])
        child.update(Array(path.dropFirst()), change)
        set(key, child)
    }

    // MARK: Text

    /// Parses JSON text. Throws on anything that is not a single JSON value.
    public init(parsing text: String) throws {
        var parser = Parser(Array(text.unicodeScalars))
        self = try parser.parseDocument()
    }

    /// The text `JSON.stringify(value, null, 2)` would produce, which is how
    /// Claude Code writes its files, followed by a newline when asked.
    public func formatted(trailingNewline: Bool = true) -> String {
        var out = ""
        write(into: &out, indent: 0)
        return trailingNewline ? out + "\n" : out
    }

    private func write(into out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent + 1)
        let closePad = String(repeating: "  ", count: indent)
        switch self {
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (index, member) in members.enumerated() {
                out += pad + Self.quoted(member.key) + ": "
                member.value.write(into: &out, indent: indent + 1)
                out += index == members.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "}"
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += pad
                item.write(into: &out, indent: indent + 1)
                out += index == items.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "]"
        case .string(let value): out += Self.quoted(value)
        case .number(let raw): out += raw
        case .bool(let value): out += value ? "true" : "false"
        case .null: out += "null"
        }
    }

    /// JSON.stringify's escaping: quotes, backslashes and control characters;
    /// everything else, including non-ASCII and "/", stays as is.
    public static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

public struct JSONParseError: Error, LocalizedError {
    public let message: String
    public let offset: Int
    public var errorDescription: String? { "JSON inválido (posição \(offset)): \(message)" }
}

private struct Parser {
    let scalars: [Unicode.Scalar]
    var index = 0

    init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == scalars.count else { throw error("texto depois do fim do JSON") }
        return value
    }

    private func error(_ message: String) -> JSONParseError { JSONParseError(message: message, offset: index) }

    private mutating func skipWhitespace() {
        while index < scalars.count, [" ", "\n", "\r", "\t"].contains(scalars[index]) { index += 1 }
    }

    private mutating func expect(_ literal: String) throws {
        for scalar in literal.unicodeScalars {
            guard index < scalars.count, scalars[index] == scalar else { throw error("esperava \(literal)") }
            index += 1
        }
    }

    private mutating func parseValue() throws -> JSONValue {
        guard index < scalars.count else { throw error("fim inesperado") }
        switch scalars[index] {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"": return .string(try parseString())
        case "t": try expect("true"); return .bool(true)
        case "f": try expect("false"); return .bool(false)
        case "n": try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        index += 1
        var members: [(key: String, value: JSONValue)] = []
        skipWhitespace()
        if index < scalars.count, scalars[index] == "}" { index += 1; return .object(members) }
        while true {
            skipWhitespace()
            guard index < scalars.count, scalars[index] == "\"" else { throw error("esperava uma chave") }
            let key = try parseString()
            skipWhitespace()
            try expect(":")
            skipWhitespace()
            members.append((key, try parseValue()))
            skipWhitespace()
            guard index < scalars.count else { throw error("objeto sem fim") }
            if scalars[index] == "," { index += 1; continue }
            if scalars[index] == "}" { index += 1; return .object(members) }
            throw error("esperava , ou }")
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        index += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if index < scalars.count, scalars[index] == "]" { index += 1; return .array(items) }
        while true {
            skipWhitespace()
            items.append(try parseValue())
            skipWhitespace()
            guard index < scalars.count else { throw error("lista sem fim") }
            if scalars[index] == "," { index += 1; continue }
            if scalars[index] == "]" { index += 1; return .array(items) }
            throw error("esperava , ou ]")
        }
    }

    private mutating func parseString() throws -> String {
        index += 1
        var out = String.UnicodeScalarView()
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            switch scalar {
            case "\"": return String(out)
            case "\\":
                guard index < scalars.count else { throw error("escape sem fim") }
                let escaped = scalars[index]
                index += 1
                switch escaped {
                case "\"", "\\", "/": out.append(escaped)
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "u":
                    var code = try parseHex4()
                    // A surrogate pair encodes one scalar above U+FFFF.
                    if (0xD800...0xDBFF).contains(code), index + 1 < scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" {
                        index += 2
                        let low = try parseHex4()
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let value = Unicode.Scalar(code) else { throw error("\\u inválido") }
                    out.append(value)
                default: throw error("escape inválido")
                }
            default:
                out.append(scalar)
            }
        }
        throw error("texto sem fim")
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= scalars.count,
              let value = UInt32(String(String.UnicodeScalarView(scalars[index..<index + 4])), radix: 16) else {
            throw error("\\u inválido")
        }
        index += 4
        return value
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = index
        while index < scalars.count, "-+.eE0123456789".unicodeScalars.contains(scalars[index]) { index += 1 }
        guard index > start else { throw error("valor inesperado") }
        let raw = String(String.UnicodeScalarView(scalars[start..<index]))
        guard Double(raw) != nil else { throw error("número inválido") }
        return .number(raw)
    }
}


/// Edits one JSON file through `JSONValue`, keeping everything it does not
/// change. A missing file starts as `{}`.
public enum JSONEdit {
    public static func edit(_ text: String?, _ change: (inout JSONValue) throws -> Void) throws -> String {
        var value = try text.map { try JSONValue(parsing: $0) } ?? .object([])
        try change(&value)
        return value.formatted(trailingNewline: text?.hasSuffix("\n") ?? true)
    }

    /// Adds or removes names in a JSON array of strings at `path`, keeping
    /// the order of the others. An array left empty is removed.
    public static func setNames(_ names: [String], present: Bool, at path: [String], in value: inout JSONValue) {
        value.update(path) { current in
            var items = current?.arrayValue ?? []
            for name in names {
                let exists = items.contains { $0.stringValue == name }
                if present, !exists { items.append(.string(name)) }
                if !present { items.removeAll { $0.stringValue == name } }
            }
            return items.isEmpty ? nil : .array(items)
        }
    }
}
