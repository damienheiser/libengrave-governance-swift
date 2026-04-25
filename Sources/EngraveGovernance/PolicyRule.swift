import Foundation

// MARK: - Rule Trigger

/// What event type triggers a rule evaluation.
public enum RuleTrigger: String, Codable, Sendable, CaseIterable {
    case request            // Evaluate on incoming request
    case response           // Evaluate on completed response
    case toolCall           // Evaluate on tool use blocks
    case streamEvent        // Evaluate on each stream event
    case streamTextMatch    // Evaluate when streamed text matches pattern
}

// MARK: - Rule Severity

/// What action to take when a rule matches.
public enum RuleSeverity: String, Codable, Sendable, CaseIterable {
    case block   // Reject the request/event
    case warn    // Allow but log a warning
    case modify  // Allow with modifications
    case rewrite // Rewrite content
}

// MARK: - Policy Rule

/// A declarative governance rule.
public struct PolicyRule: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var trigger: RuleTrigger
    public var severity: RuleSeverity
    public var matchPatterns: [String]
    public var condition: String?
    public var modification: String?
    public var replacement: String?
    public var description: String?

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        trigger: RuleTrigger = .request,
        severity: RuleSeverity = .warn,
        matchPatterns: [String] = [],
        condition: String? = nil,
        modification: String? = nil,
        replacement: String? = nil,
        description: String? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.trigger = trigger
        self.severity = severity
        self.matchPatterns = matchPatterns
        self.condition = condition
        self.modification = modification
        self.replacement = replacement
        self.description = description
    }

    // MARK: - Built-in Rule Templates

    public static let blockDangerousBash = PolicyRule(
        name: "Block dangerous bash commands",
        trigger: .toolCall,
        severity: .block,
        matchPatterns: ["rm\\s+-rf", "sudo\\s+", "chmod\\s+777", "mkfs", "dd\\s+if=", "> /dev/"],
        description: "Blocks bash commands that could damage the system"
    )

    public static let warnLargeTokenUsage = PolicyRule(
        name: "Warn on high token usage",
        trigger: .request,
        severity: .warn,
        condition: "tokens_used > tokens_budget * 0.8",
        description: "Warns when token usage exceeds 80% of budget"
    )

    public static let blockSensitivePaths = PolicyRule(
        name: "Block access to sensitive paths",
        trigger: .toolCall,
        severity: .block,
        matchPatterns: ["\\.env$", "credentials", "\\.ssh/", "\\.aws/", "secrets\\."],
        description: "Blocks tool calls that access sensitive files"
    )

    public static let warnExternalNetwork = PolicyRule(
        name: "Warn on external network access",
        trigger: .toolCall,
        severity: .warn,
        matchPatterns: ["curl\\s+", "wget\\s+", "http://[^l]", "https://"],
        description: "Warns when tools attempt external network access"
    )
}
