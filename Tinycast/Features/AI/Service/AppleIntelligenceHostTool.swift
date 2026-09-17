import FoundationModels
import Foundation

/// Bridges one Tinycast `AITool` into a FoundationModels tool the on-device session runs in-process.
/// The HTTP routes hand tool calls back through `AIToolLoopProvider`; the on-device model executes
/// them itself, so the tool carries the same executor and reports each call to the transcript.
struct AppleIntelligenceHostTool: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    private let origin: String
    private let title: String
    private let execute: @Sendable (AIToolCall) async -> AIToolResult
    private let emit: @Sendable (AIStreamEvent) -> Void

    init(
        spec: AITool,
        execute: @escaping @Sendable (AIToolCall) async -> AIToolResult,
        emit: @escaping @Sendable (AIStreamEvent) -> Void
    ) throws {
        name = spec.name
        description = spec.description
        parameters = try AppleIntelligenceToolSchema.schema(for: spec)
        origin = spec.origin
        title = spec.title
        self.execute = execute
        self.emit = emit
    }

    /// A tool failure is content the model reads and recovers from, so this never throws.
    func call(arguments: GeneratedContent) async -> String {
        let id = UUID().uuidString
        emit(.toolCall(id: id, origin: origin, title: title))
        let result = await execute(
            AIToolCall(id: id, name: name, arguments: arguments.jsonString))
        emit(.toolResult(id: id, isError: result.isError))
        return result.content
    }
}

/// Turns an `AITool`'s JSON-Schema parameters into the dynamic schema FoundationModels wants.
/// Names are path-derived so every nested object stays unique across the one schema.
enum AppleIntelligenceToolSchema {
    static func schema(for tool: AITool) throws -> GenerationSchema {
        try GenerationSchema(root: node(named: tool.name, from: tool.parameters), dependencies: [])
    }

    private static func node(named name: String, from value: JSONValue) -> DynamicGenerationSchema {
        let fields = value.objectValue ?? [:]
        let description = fields["description"]?.stringValue
        if let choices = fields["enum"]?.arrayValue?.compactMap(\.stringValue), !choices.isEmpty {
            return DynamicGenerationSchema(name: name, description: description, anyOf: choices)
        }
        switch fields["type"]?.stringValue {
        case "object":
            let properties = fields["properties"]?.objectValue ?? [:]
            let required = Set(fields["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            return DynamicGenerationSchema(
                name: name, description: description,
                properties: properties.map { key, schema in
                    DynamicGenerationSchema.Property(
                        name: key, description: schema.objectValue?["description"]?.stringValue,
                        schema: node(named: name + "." + key, from: schema),
                        isOptional: !required.contains(key))
                })
        case "array":
            return DynamicGenerationSchema(
                arrayOf: node(named: name + ".item", from: fields["items"] ?? .object([:])))
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        // "string" and anything the model can still fill as free text.
        default:
            return DynamicGenerationSchema(type: String.self)
        }
    }
}
