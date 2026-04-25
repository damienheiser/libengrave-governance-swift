import Foundation
import EngraveInterposer

/// The main governance policy engine.
/// Evaluates requests, responses, stream events, and tool calls
/// against configured rules and sandbox restrictions.
public actor PolicyEngine {
    private var config: GovernanceConfig
    private var toolInterceptor: ToolInterceptor
    private let conditionEvaluator = ConditionEvaluator()
    private var compiledRules: [(rule: PolicyRule, regexes: [NSRegularExpression])] = []
    public private(set) var context: GovernanceContext
    public private(set) var eventLog: [GovernanceEvent] = []

    public var isEnabled: Bool { config.enabled }
    public var currentConfig: GovernanceConfig { config }

    public init(config: GovernanceConfig = GovernanceConfig()) {
        self.config = config
        self.context = GovernanceContext(
            sandboxLevel: config.sandboxLevel,
            tokensBudget: config.maxTokensBudget ?? 100_000
        )
        self.toolInterceptor = ToolInterceptor(
            sandboxLevel: config.sandboxLevel,
            blockedPaths: config.blockedPaths,
            blockedCommands: config.blockedCommands,
            requireApprovalForTools: Set(config.requireApprovalForTools)
        )
        compileRules()
    }

    /// Update configuration (recompiles rules)
    public func updateConfig(_ newConfig: GovernanceConfig) {
        config = newConfig
        context = GovernanceContext(
            sessionId: context.sessionId,
            agentId: context.agentId,
            sandboxLevel: newConfig.sandboxLevel,
            tokensUsed: context.tokensUsed,
            tokensBudget: newConfig.maxTokensBudget ?? 100_000,
            model: context.model,
            requestCount: context.requestCount
        )
        toolInterceptor = ToolInterceptor(
            sandboxLevel: newConfig.sandboxLevel,
            blockedPaths: newConfig.blockedPaths,
            blockedCommands: newConfig.blockedCommands,
            requireApprovalForTools: Set(newConfig.requireApprovalForTools)
        )
        compileRules()
    }

    private func compileRules() {
        compiledRules = config.rules.filter(\.enabled).map { rule in
            let regexes = rule.matchPatterns.compactMap { pattern in
                try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            }
            return (rule, regexes)
        }
    }

    // MARK: - Request Evaluation

    /// Evaluate an incoming request against all governance rules.
    public func evaluateRequest(_ request: CanonicalRequest) -> PolicyDecision {
        guard config.enabled else { return .allow }

        context.model = request.model
        context.requestCount += 1

        // Sandbox check: jailed blocks all
        if config.sandboxLevel == .jailed {
            let decision = PolicyDecision.block(reason: "Sandbox level is jailed — all requests blocked")
            logEvent(eventType: "request", decision: decision)
            return decision
        }

        // Token budget check
        if let budget = config.maxTokensBudget {
            if context.tokensUsed >= budget {
                let decision = PolicyDecision.block(reason: "Token budget exhausted (\(context.tokensUsed)/\(budget))")
                logEvent(eventType: "request", decision: decision)
                return decision
            }
            if Double(context.tokensUsed) > Double(budget) * 0.9 {
                logEvent(eventType: "request", decision: .warn(reason: "Token usage at 90%+ of budget"))
            }
        }

        // Evaluate declarative rules
        let text = extractRequestText(request)
        let decision = evaluateRules(text: text, trigger: .request)
        logEvent(eventType: "request", decision: decision, ruleName: matchedRuleName(text: text, trigger: .request))
        return decision
    }

    // MARK: - Stream Event Evaluation

    /// Evaluate a streaming event against governance rules.
    public func evaluateStreamEvent(_ event: CanonicalStreamEvent) -> PolicyDecision {
        guard config.enabled else { return .allow }

        switch event {
        case .textDelta(_, let text):
            let decision = evaluateRules(text: text, trigger: .streamTextMatch)
            if !decision.isAllowed {
                logEvent(eventType: "stream", decision: decision)
            }
            return decision
        case .toolInputDelta(_, let json):
            let decision = evaluateRules(text: json, trigger: .streamEvent)
            return decision
        default:
            return .allow
        }
    }

    // MARK: - Tool Call Evaluation

    /// Evaluate a tool call against interception rules.
    public func evaluateToolCall(name: String, input: [String: Any]) -> PolicyDecision {
        guard config.enabled else { return .allow }

        // Tool interception
        let interceptDecision = toolInterceptor.evaluateToolCall(name: name, input: input)
        if !interceptDecision.isAllowed {
            logEvent(eventType: "tool_call", decision: interceptDecision, ruleName: "tool_interception")
            return interceptDecision
        }

        // Check tool-specific rules
        let toolText = "\(name) \(input.description)"
        let ruleDecision = evaluateRules(text: toolText, trigger: .toolCall)
        logEvent(eventType: "tool_call", decision: ruleDecision, ruleName: matchedRuleName(text: toolText, trigger: .toolCall))
        return ruleDecision
    }

    // MARK: - Usage Tracking

    /// Update token usage from a response
    public func recordUsage(_ usage: Usage) {
        context.tokensUsed += usage.inputTokens + usage.outputTokens
    }

    /// Reset session state
    public func resetSession() {
        context = GovernanceContext(
            sandboxLevel: config.sandboxLevel,
            tokensBudget: config.maxTokensBudget ?? 100_000
        )
        eventLog.removeAll()
    }

    /// Get recent events (last N)
    public func recentEvents(count: Int = 50) -> [GovernanceEvent] {
        Array(eventLog.suffix(count))
    }

    // MARK: - Internal

    private func evaluateRules(text: String, trigger: RuleTrigger) -> PolicyDecision {
        var worstDecision = PolicyDecision.allow

        for (rule, regexes) in compiledRules where rule.trigger == trigger {
            // Check condition
            if !conditionEvaluator.evaluate(rule.condition, context: context) {
                continue
            }

            // Check match patterns (if any)
            if !regexes.isEmpty {
                let range = NSRange(text.startIndex..., in: text)
                let matched = regexes.contains { $0.firstMatch(in: text, range: range) != nil }
                if !matched { continue }
            }

            // Rule matched — determine decision
            let decision: PolicyDecision
            switch rule.severity {
            case .block: decision = .block(reason: "Rule '\(rule.name)' triggered")
            case .warn: decision = .warn(reason: "Rule '\(rule.name)' triggered")
            case .modify: decision = .modify(field: rule.modification ?? "", value: "")
            case .rewrite: decision = .rewrite(replacementText: rule.replacement ?? "")
            }

            if decision.severity > worstDecision.severity {
                worstDecision = decision
            }
        }

        return worstDecision
    }

    private func matchedRuleName(text: String, trigger: RuleTrigger) -> String? {
        for (rule, regexes) in compiledRules where rule.trigger == trigger {
            if !conditionEvaluator.evaluate(rule.condition, context: context) { continue }
            if regexes.isEmpty { return rule.name }
            let range = NSRange(text.startIndex..., in: text)
            if regexes.contains(where: { $0.firstMatch(in: text, range: range) != nil }) {
                return rule.name
            }
        }
        return nil
    }

    private func extractRequestText(_ request: CanonicalRequest) -> String {
        var parts: [String] = []
        if let system = request.system { parts.append(system) }
        for msg in request.messages {
            for block in msg.content {
                switch block {
                case .text(let t): parts.append(t.text)
                case .toolUse(let t): parts.append("\(t.name) \(t.input)")
                case .toolResult(let t): parts.append(t.content)
                default: break
                }
            }
        }
        return parts.joined(separator: " ")
    }

    private func logEvent(eventType: String, decision: PolicyDecision, ruleName: String? = nil) {
        let decisionStr: String
        switch decision {
        case .allow: decisionStr = "allow"
        case .warn: decisionStr = "warn"
        case .block: decisionStr = "block"
        case .modify: decisionStr = "modify"
        case .rewrite: decisionStr = "rewrite"
        }
        let event = GovernanceEvent(
            eventType: eventType,
            ruleName: ruleName,
            decision: decisionStr,
            reason: decision.reason,
            model: context.model,
            sessionId: context.sessionId
        )
        eventLog.append(event)
        // Cap log at 1000 entries
        if eventLog.count > 1000 { eventLog.removeFirst(eventLog.count - 1000) }
    }
}
