// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Values crossing the constrained module interface. There are no handles, URLs,
/// callbacks, filesystem operations, or evaluation of JavaScript in this runtime.
public indirect enum ModuleValue: Codable, Equatable, Sendable {
    case string(String), bool(Bool), integer(Int), object([String: ModuleValue]), array([ModuleValue]), null
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Int.self) { self = .integer(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([String: ModuleValue].self) { self = .object(v) }
        else { self = .array(try value.decode([ModuleValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .integer(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var integer: Int? { if case .integer(let value) = self { value } else { nil } }
    public var object: [String: ModuleValue]? { if case .object(let value) = self { value } else { nil } }
    public var array: [ModuleValue]? { if case .array(let value) = self { value } else { nil } }
    public func validate(depth: Int = 0) throws {
        guard depth <= 16 else { throw ValidationError("Module data is nested too deeply.") }
        switch self {
        case .string(let value): guard value.utf8.count <= 1_000_000 else { throw ValidationError("Module text is too large.") }
        case .array(let values):
            guard values.count <= 64 else { throw ValidationError("Module arrays are too large.") }
            for value in values { try value.validate(depth: depth + 1) }
        case .object(let values):
            guard values.count <= 64, values.keys.allSatisfy(ModuleProgram.validKey) else { throw ValidationError("Module fields are invalid.") }
            for value in values.values { try value.validate(depth: depth + 1) }
        default: break
        }
    }
}

public struct ModuleExpression: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable { case literal, input, prefix, equal, choose, object }
    public var op: Operation
    public var value: ModuleValue?
    public var key: String?
    public var limit: Int?
    public var arguments: [ModuleExpression]?
    public var fields: [String: ModuleExpression]?
    public init(op: Operation, value: ModuleValue? = nil, key: String? = nil, limit: Int? = nil,
                arguments: [ModuleExpression]? = nil, fields: [String: ModuleExpression]? = nil) {
        self.op = op; self.value = value; self.key = key; self.limit = limit; self.arguments = arguments; self.fields = fields
    }
    fileprivate func validate(depth: Int, budget: inout Int) throws {
        budget -= 1
        guard depth <= 16, budget >= 0 else { throw ValidationError("Module programs exceed the instruction limit.") }
        let expectedArguments = switch op { case .prefix: 1; case .equal: 2; case .choose: 3; default: 0 }
        guard (arguments?.count ?? 0) == expectedArguments else { throw ValidationError("A module instruction has invalid arguments.") }
        switch op {
        case .literal: guard let value else { throw ValidationError("A literal needs a value.") }; try value.validate()
        case .input: guard let key, ModuleProgram.validKey(key) else { throw ValidationError("A module input name is invalid.") }
        case .prefix: guard let limit, (0...200_000).contains(limit) else { throw ValidationError("A text limit is invalid.") }
        case .object: guard let fields, fields.count <= 32, fields.keys.allSatisfy(ModuleProgram.validKey) else { throw ValidationError("Module output fields are invalid.") }
        default: break
        }
        guard op == .literal || value == nil, op == .input || key == nil, op == .prefix || limit == nil,
              op == .object || fields == nil else { throw ValidationError("A module instruction contains unsupported properties.") }
        for argument in arguments ?? [] { try argument.validate(depth: depth + 1, budget: &budget) }
        for field in fields?.values ?? Dictionary<String, ModuleExpression>().values { try field.validate(depth: depth + 1, budget: &budget) }
    }
    fileprivate func evaluate(_ input: [String: ModuleValue]) throws -> ModuleValue {
        switch op {
        case .literal: return value!
        case .input: return input[key!] ?? .null
        case .prefix:
            guard let text = try arguments![0].evaluate(input).string else { throw ValidationError("This module expected text.") }
            return .string(String(text.prefix(limit!)))
        case .equal: return .bool(try arguments![0].evaluate(input) == arguments![1].evaluate(input))
        case .choose:
            guard let condition = try arguments![0].evaluate(input).bool else { throw ValidationError("This module expected a condition.") }
            return try arguments![condition ? 1 : 2].evaluate(input)
        case .object: return .object(try fields!.mapValues { try $0.evaluate(input) })
        }
    }
}

/// Small, terminating expression programs supply feature behavior. Radius only
/// applies validated output through native presentation and browser services.
public struct ModuleProgram: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var entrypoints: [String: ModuleExpression]
    public init(entrypoints: [String: ModuleExpression]) { formatVersion = 1; self.entrypoints = entrypoints }
    public static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 64 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-") }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 128 * 1024 else { throw ValidationError("Behavior programs exceed 128 KB.") }
        try ModuleJSONBounds.validate(data)
        let program = try JSONDecoder().decode(Self.self, from: data)
        try program.validate(); return program
    }
    public func validate() throws {
        guard formatVersion == 1, !entrypoints.isEmpty, entrypoints.count <= 16,
              entrypoints.keys.allSatisfy(Self.validKey) else { throw ValidationError("This behavior program is incompatible with Radius.") }
        var budget = 512
        for expression in entrypoints.values { try expression.validate(depth: 0, budget: &budget) }
    }
    public func validate(capability: ModuleCapability) throws {
        try validate()
        let required: Set<String>
        switch capability {
        case .notes: required = ["create", "update", "delete"]
        case .screenshot: required = ["prepare"]
        case .focusMode: required = ["enter", "exit"]
        default: throw ValidationError("This role does not support a behavior program.")
        }
        guard required.isSubset(of: Set(entrypoints.keys)) else { throw ValidationError("This behavior package does not implement every required operation for its role.") }
    }
    public func run(_ event: String, input: [String: ModuleValue]) throws -> [String: ModuleValue] {
        try validate(); try ModuleValue.object(input).validate()
        guard try JSONEncoder().encode(input).count <= 1_048_576 else { throw ValidationError("Module input exceeds 1 MB.") }
        guard let expression = entrypoints[event] else { throw ValidationError("This module does not implement \(event).") }
        guard let output = try expression.evaluate(input).object else { throw ValidationError("A module must return named values.") }
        try ModuleValue.object(output).validate()
        guard try JSONEncoder().encode(output).count <= 1_048_576 else { throw ValidationError("Module output exceeds 1 MB.") }
        return output
    }
}

public struct ModuleSetting: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case toggle, choice, text, integer }
    public var id: String
    public var title: String
    public var kind: Kind
    public var defaultValue: ModuleValue
    public var choices: [String]?
    public func validate() throws {
        guard ModuleProgram.validKey(id), !title.isEmpty, title.count <= 100 else { throw ValidationError("A module setting is invalid.") }
        try validate(value: defaultValue)
    }
    public func validate(value: ModuleValue) throws {
        switch kind {
        case .toggle: guard value.bool != nil else { throw ValidationError("This setting needs a toggle value.") }
        case .choice:
            guard let choices, !choices.isEmpty, choices.count <= 32, choices.allSatisfy({ !$0.isEmpty && $0.count <= 100 }),
                  Set(choices).count == choices.count, let text = value.string, choices.contains(text) else { throw ValidationError("This setting needs a listed choice.") }
        case .text: guard let text = value.string, text.count <= 1000 else { throw ValidationError("This setting needs at most 1,000 characters.") }
        case .integer: guard let number = value.integer, (0...200_000).contains(number) else { throw ValidationError("This number must be between 0 and 200,000.") }
        }
    }
}

public enum NativeModuleAction: String, Codable, CaseIterable, Sendable {
    case newTab, bookmarks, history, downloads, modules, customize, settings, recovery
}
public struct ModuleMenuItem: Codable, Equatable, Sendable { public var title: String; public var action: NativeModuleAction }
public struct ModuleDefinition: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var treeTabs: Bool?
    public var theme: Theme?
    public var layout: BrowserLayout?
    public var icons: [String: String]?
    public var menu: [ModuleMenuItem]?
    public var widgetTitle: String?
    public var widgetBody: String?
    public static func decode(_ data: Data, capability: ModuleCapability) throws -> Self {
        guard data.count <= 128 * 1024 else { throw ValidationError("Declarative packages exceed 128 KB.") }
        try ModuleJSONBounds.validate(data)
        let definition = try JSONDecoder().decode(Self.self, from: data)
        try definition.validate(capability: capability); return definition
    }
    public func validate(capability: ModuleCapability) throws {
        guard formatVersion == 1 else { throw ValidationError("This declarative module is incompatible with Radius.") }
        let populated = [treeTabs != nil, theme != nil, layout != nil, icons != nil, menu != nil, widgetTitle != nil || widgetBody != nil].filter { $0 }.count
        guard populated == 1 else { throw ValidationError("A declarative package must define exactly one role.") }
        switch capability {
        case .tabSystem: guard treeTabs != nil else { throw ValidationError("A tab system must choose its tab presentation.") }
        case .theme:
            guard let theme else { throw ValidationError("Invalid theme values.") }
            var normalized = theme; normalized.normalize()
            guard normalized == theme else { throw ValidationError("Theme values exceed Radius's supported ranges.") }
            guard (theme.surfaceHex == nil) == (theme.textHex == nil) else { throw ValidationError("Custom theme surface and text colors must be supplied together.") }
            if let surface = theme.surfaceHex, let text = theme.textHex,
               let a = InterfaceColor(hex: surface), let b = InterfaceColor(hex: text) {
                guard a.contrastRatio(against: b) >= 4.5 else { throw ValidationError("Theme text must meet the 4.5:1 contrast threshold against its surface.") }
            }
        case .layout:
            guard let layout else { throw ValidationError("Invalid layout values.") }
            var normalized = layout; normalized.normalize()
            guard normalized == layout else { throw ValidationError("Layout values exceed Radius's supported ranges.") }
        case .icons:
            let supported = Set(ToolbarCommand.allCases.map(\.rawValue)).union(["bookmarks", "history", "notes", "resources"])
            guard let icons, !icons.isEmpty, icons.count <= 32, Set(icons.keys).isSubset(of: supported),
                  icons.values.allSatisfy({ !$0.isEmpty && $0.count <= 80 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") } }) else { throw ValidationError("Invalid native symbol names.") }
        case .menu:
            guard let menu, !menu.isEmpty, menu.count <= 16, menu.allSatisfy({ !$0.title.isEmpty && $0.title.count <= 80 }) else { throw ValidationError("Invalid menu items.") }
        case .startWidget:
            guard let widgetTitle, let widgetBody, !widgetTitle.isEmpty, widgetTitle.count <= 100, widgetBody.count <= 1000 else { throw ValidationError("Invalid start-page widget.") }
        default: throw ValidationError("This role cannot use a declarative package.")
        }
    }
}

/// Community catalogs carry only bounded data/programs, never downloaded native
/// executables. Claimed publishers are labels, not a verified signing identity.
public struct DeclarativeModulePackage: Codable, Equatable, Sendable {
    public var manifest: ModuleManifest
    public var program: ModuleProgram?
    public var definition: ModuleDefinition?
    public init(manifest: ModuleManifest, program: ModuleProgram? = nil, definition: ModuleDefinition? = nil) {
        self.manifest = manifest; self.program = program; self.definition = definition
    }
    public func payload() throws -> Data {
        try manifest.validate()
        switch manifest.runtime {
        case .behaviorProgram:
            guard let program, definition == nil else { throw ValidationError("A behavior package needs its program.") }
            try program.validate(capability: manifest.capability); return try JSONEncoder().encode(program)
        case .declarative:
            guard let definition, program == nil else { throw ValidationError("A declarative package needs its definition.") }
            try definition.validate(capability: manifest.capability); return try JSONEncoder().encode(definition)
        default: throw ValidationError("Community packages cannot contain native code or descriptor-only features.")
        }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 192 * 1024 else { throw ValidationError("Local packages exceed 192 KB.") }
        try ModuleJSONBounds.validate(data)
        let package = try JSONDecoder().decode(Self.self, from: data); _ = try package.payload(); return package
    }
}
public struct DeclarativeModuleCatalog: Codable, Sendable {
    public var formatVersion: Int
    public var name: String
    public var packages: [DeclarativeModulePackage]
    public var sourceURL: URL?
    public init(formatVersion: Int = 1, name: String, packages: [DeclarativeModulePackage], sourceURL: URL? = nil) {
        self.formatVersion = formatVersion; self.name = name; self.packages = packages; self.sourceURL = sourceURL
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 2 * 1024 * 1024 else { throw ValidationError("Catalogs exceed 2 MB.") }
        try ModuleJSONBounds.validate(data)
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.formatVersion == 1, !catalog.name.isEmpty, catalog.name.count <= 100, catalog.packages.count <= 64,
              Set(catalog.packages.map { $0.manifest.id }).count == catalog.packages.count else { throw ValidationError("Invalid community catalog.") }
        if let url = catalog.sourceURL {
            guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw ValidationError("A catalog source must be an HTTPS URL without credentials.") }
        }
        for package in catalog.packages { _ = try package.payload() }
        return catalog
    }
}

/// Bound nesting before recursive Codable decoding can allocate or recurse.
public enum ModuleJSONBounds {
    public static func validate(_ data: Data) throws {
        var depth = 0, quoted = false, escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= 64 else { throw ValidationError("Module JSON exceeds the nesting limit.") }
            } else if byte == 125 || byte == 93 {
                depth -= 1
                guard depth >= 0 else { throw ValidationError("Module JSON is malformed.") }
            }
        }
        guard depth == 0, !quoted else { throw ValidationError("Module JSON is incomplete.") }
    }
}
