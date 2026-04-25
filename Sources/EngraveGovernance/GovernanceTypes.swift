import Foundation
import EngraveInterposer

// MARK: - Policy Decision

/// The result of evaluating a request/event against governance rules.
public enum PolicyDecision: Sendable {
    case allow
    case warn(reason: String)
    case block(reason: String)
    case modify(field: String, value: String)
    case rewrite(replacementText: String)

    public var isAllowed: Bool {
        switch self {
        case .allow, .warn: return true
        default: return false
        }
    }

    public var severity: Int {
        switch self {
        case .allow: return 0
        case .warn: return 1
        case .modify: return 2
        case .rewrite: return 3
        case .block: return 4
        }
    }

    public var reason: String? {
        switch self {
        case .allow: return nil
        case .warn(let r), .block(let r): return r
        case .modify(let f, _): return "Modified: \(f)"
        case .rewrite: return "Content rewritten"
        }
    }
}

// MARK: - Sandbox Level

/// Security tier controlling what tools/paths agents can access.
public enum SandboxLevel: String, Codable, Sendable, Comparable, CaseIterable {
    case jailed     // No execution at all
    case sandbox    // Read-only, restricted paths
    case workspace  // Read-write within project directory
    case full       // System-wide access (requires explicit config)

    public static func < (lhs: SandboxLevel, rhs: SandboxLevel) -> Bool {
        let order: [SandboxLevel] = [.jailed, .sandbox, .workspace, .full]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

// MARK: - Governance Context

/// Ambient context passed to rule evaluations — tracks session state.
public struct GovernanceContext: Sendable {
    public var sessionId: String
    public var agentId: String
    public var sandboxLevel: SandboxLevel
    public var tokensUsed: UInt32
    public var tokensBudget: UInt32
    public var model: String
    public var requestCount: UInt32

    public init(
        sessionId: String = UUID().uuidString,
        agentId: String = "default",
        sandboxLevel: SandboxLevel = .workspace,
        tokensUsed: UInt32 = 0,
        tokensBudget: UInt32 = 100_000,
        model: String = "unknown",
        requestCount: UInt32 = 0
    ) {
        self.sessionId = sessionId
        self.agentId = agentId
        self.sandboxLevel = sandboxLevel
        self.tokensUsed = tokensUsed
        self.tokensBudget = tokensBudget
        self.model = model
        self.requestCount = requestCount
    }

    /// Resolve a field name to its value for condition evaluation
    public func resolveField(_ name: String) -> Double? {
        switch name {
        case "tokens_used": return Double(tokensUsed)
        case "tokens_budget": return Double(tokensBudget)
        case "request_count": return Double(requestCount)
        default: return nil
        }
    }

    public func resolveStringField(_ name: String) -> String? {
        switch name {
        case "sandbox_level": return sandboxLevel.rawValue
        case "model": return model
        case "agent_id": return agentId
        case "session_id": return sessionId
        default: return nil
        }
    }
}

// MARK: - Governance Event

/// A logged governance decision for the audit trail.
public struct GovernanceEvent: Codable, Sendable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var eventType: String      // "request", "stream", "tool_call"
    public var ruleName: String?
    public var decision: String       // "allow", "warn", "block", "modify", "rewrite"
    public var reason: String?
    public var model: String?
    public var sessionId: String?

    public init(
        eventType: String, ruleName: String? = nil,
        decision: String, reason: String? = nil,
        model: String? = nil, sessionId: String? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.eventType = eventType
        self.ruleName = ruleName
        self.decision = decision
        self.reason = reason
        self.model = model
        self.sessionId = sessionId
    }
}

// MARK: - Tool Risk

/// Risk classification for tool calls.
public enum ToolRisk: String, Sendable {
    case safe              // Read, Glob, Grep — read-only
    case needsGovernance   // Write, Edit, Bash — modifies state
    case dangerous         // rm, kill, network — system-level impact
}
