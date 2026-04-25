import Foundation
import EngraveInterposer

/// Bridges the PolicyEngine to the GovernanceEvaluator protocol
/// used by the interposer's ConnectionHandler.
public final class GovernanceBridge: GovernanceEvaluator, @unchecked Sendable {
    private let engine: PolicyEngine

    public init(engine: PolicyEngine) {
        self.engine = engine
    }

    public func evaluateRequest(_ body: [String: Any], provider: String) async -> (allowed: Bool, reason: String?) {
        let canonical = parseRequestForGovernance(body, provider: provider)
        let decision = await engine.evaluateRequest(canonical)
        return (decision.isAllowed, decision.reason)
    }

    public func evaluateToolCall(name: String, input: [String: Any]) async -> (allowed: Bool, reason: String?) {
        let decision = await engine.evaluateToolCall(name: name, input: input)
        return (decision.isAllowed, decision.reason)
    }

    public func evaluateStreamText(_ text: String) async -> (allowed: Bool, reason: String?) {
        let event = CanonicalStreamEvent.textDelta(index: 0, text: text)
        let decision = await engine.evaluateStreamEvent(event)
        return (decision.isAllowed, decision.reason)
    }

    /// Get the underlying engine for direct access (config updates, event log, etc.)
    public var policyEngine: PolicyEngine { engine }

    private func parseRequestForGovernance(_ body: [String: Any], provider: String) -> CanonicalRequest {
        switch provider {
        case "anthropic":
            return MessageTranslator.parseAnthropicRequest(body)
        case "openai_compatible":
            return MessageTranslator.parseChatCompletionsRequest(body)
        case "openai":
            return MessageTranslator.parseOpenAIRequest(body)
        case "gemini":
            return MessageTranslator.parseGeminiRequest(body)
        default:
            return MessageTranslator.parseChatCompletionsRequest(body)
        }
    }
}
