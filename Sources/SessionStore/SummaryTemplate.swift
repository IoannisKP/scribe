import Foundation

public struct SummaryTemplate: Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var body: String
    public let builtInKey: String?
    public let sortOrder: Int
    public let createdAt: Date
    public var updatedAt: Date

    public var isBuiltIn: Bool { builtInKey != nil }

    public init(
        id: String,
        name: String,
        body: String,
        builtInKey: String? = nil,
        sortOrder: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.body = body
        self.builtInKey = builtInKey
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct SummaryTemplateContext: Equatable, Sendable {
    public let notes: String
    public let transcript: String
    public let title: String
    public let date: String
    public let participants: String
    public let pins: String

    public init(
        notes: String,
        transcript: String,
        title: String,
        date: String,
        participants: String,
        pins: String
    ) {
        self.notes = notes
        self.transcript = transcript
        self.title = title
        self.date = date
        self.participants = participants
        self.pins = pins
    }

    fileprivate func value(for variable: String) -> String? {
        switch variable {
        case "notes": notes
        case "transcript": transcript
        case "title": title
        case "date": date
        case "participants": participants
        case "pins": pins
        default: nil
        }
    }
}

public enum SummaryTemplateRenderer {
    public static let supportedVariables = [
        "notes", "transcript", "title", "date", "participants", "pins"
    ]

    public static func render(
        _ template: SummaryTemplate,
        context: SummaryTemplateContext
    ) throws -> String {
        let expression = try NSRegularExpression(
            pattern: #"\{\{\s*([A-Za-z][A-Za-z0-9_]*)\s*\}\}"#
        )
        var result = template.body
        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        let matches = expression.matches(in: result, range: range)

        for match in matches.reversed() {
            guard
                let variableRange = Range(match.range(at: 1), in: result),
                let replacementRange = Range(match.range(at: 0), in: result)
            else {
                throw SummaryTemplateError.malformedVariable
            }
            let variable = String(result[variableRange])
            guard let value = context.value(for: variable) else {
                throw SummaryTemplateError.unknownVariable(variable)
            }
            result.replaceSubrange(replacementRange, with: value)
        }

        if result.contains("{{") || result.contains("}}") {
            throw SummaryTemplateError.malformedVariable
        }
        return result
    }
}

public enum SummaryTemplateError: Error, Equatable, LocalizedError, Sendable {
    case missingName
    case missingBody
    case templateNotFound
    case builtInTemplateCannotBeDeleted
    case unknownVariable(String)
    case malformedVariable

    public var errorDescription: String? {
        switch self {
        case .missingName:
            ScribeCopy.SummaryTemplates.missingName
        case .missingBody:
            ScribeCopy.SummaryTemplates.missingBody
        case .templateNotFound:
            ScribeCopy.SummaryTemplates.notFound
        case .builtInTemplateCannotBeDeleted:
            ScribeCopy.SummaryTemplates.builtInCannotBeDeleted
        case let .unknownVariable(variable):
            ScribeCopy.SummaryTemplates.unknownVariable(variable)
        case .malformedVariable:
            ScribeCopy.SummaryTemplates.malformedVariable
        }
    }
}
