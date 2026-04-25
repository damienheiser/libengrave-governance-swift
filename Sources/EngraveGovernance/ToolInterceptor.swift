import Foundation
import EngraveInterposer

/// Intercepts and classifies tool calls from AI agents.
/// Enforces sandbox-level restrictions and blocked path/command patterns.
public struct ToolInterceptor: Sendable {
    public let sandboxLevel: SandboxLevel
    public let blockedPaths: [String]
    public let blockedCommands: [String]
    public let requireApprovalForTools: Set<String>
    private let blockedPathRegexes: [NSRegularExpression]
    private let blockedCommandRegexes: [NSRegularExpression]

    public init(
        sandboxLevel: SandboxLevel = .workspace,
        blockedPaths: [String] = [],
        blockedCommands: [String] = [],
        requireApprovalForTools: Set<String> = []
    ) {
        self.sandboxLevel = sandboxLevel
        self.blockedPaths = blockedPaths
        self.blockedCommands = blockedCommands
        self.requireApprovalForTools = requireApprovalForTools
        self.blockedPathRegexes = blockedPaths.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
        self.blockedCommandRegexes = blockedCommands.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }

    // MARK: - Tool Classification

    /// Classify a tool by name into a risk level.
    public func classifyTool(_ toolName: String) -> ToolRisk {
        switch toolName.lowercased() {
        case "read", "glob", "grep", "ls", "find", "cat", "head", "tail":
            return .safe
        case "write", "edit", "notebookedit", "mv", "cp":
            return .needsGovernance
        case "bash", "shell", "exec", "run":
            return .needsGovernance
        case "rm", "kill", "pkill", "chmod", "chown", "sudo":
            return .dangerous
        default:
            return .needsGovernance
        }
    }

    /// Evaluate a tool call against governance rules.
    public func evaluateToolCall(name: String, input: [String: Any]) -> PolicyDecision {
        // Jailed sandbox blocks everything
        if sandboxLevel == .jailed {
            return .block(reason: "Sandbox level is jailed — all tool execution is blocked")
        }

        let risk = classifyTool(name)

        // Check if tool requires explicit approval
        if requireApprovalForTools.contains(name) {
            return .block(reason: "Tool '\(name)' requires explicit approval")
        }

        // Dangerous tools blocked unless full sandbox
        if risk == .dangerous && sandboxLevel < .full {
            return .block(reason: "Dangerous tool '\(name)' blocked at sandbox level \(sandboxLevel.rawValue)")
        }

        // Check tool-specific inputs
        switch name.lowercased() {
        case "bash", "shell", "exec":
            return evaluateBashCommand(input)
        case "write", "edit", "read":
            return evaluateFileAccess(name, input: input)
        default:
            break
        }

        // NeedsGovernance tools in sandbox mode
        if risk == .needsGovernance && sandboxLevel == .sandbox {
            return .warn(reason: "Tool '\(name)' used in sandbox mode — write operations restricted")
        }

        return .allow
    }

    // MARK: - Bash Command Evaluation

    private func evaluateBashCommand(_ input: [String: Any]) -> PolicyDecision {
        guard let command = input["command"] as? String else { return .allow }

        // Check against blocked command patterns
        for regex in blockedCommandRegexes {
            let range = NSRange(command.startIndex..., in: command)
            if regex.firstMatch(in: command, range: range) != nil {
                return .block(reason: "Blocked command pattern: \(command.prefix(100))")
            }
        }

        // Sandbox-level restrictions
        if sandboxLevel <= .sandbox {
            // Block write/modify commands in sandbox
            let writeCommands = ["rm", "mv", "cp", "mkdir", "rmdir", "chmod", "chown", "touch",
                                "echo >", "cat >", "tee", "dd", "install"]
            for wc in writeCommands {
                if command.contains(wc) {
                    return .block(reason: "Write command '\(wc)' blocked in sandbox mode")
                }
            }
        }

        return .allow
    }

    // MARK: - File Access Evaluation

    private func evaluateFileAccess(_ toolName: String, input: [String: Any]) -> PolicyDecision {
        let path = (input["file_path"] as? String) ?? (input["path"] as? String) ?? ""
        guard !path.isEmpty else { return .allow }

        // Check against blocked path patterns
        for regex in blockedPathRegexes {
            let range = NSRange(path.startIndex..., in: path)
            if regex.firstMatch(in: path, range: range) != nil {
                return .block(reason: "Access to blocked path: \(path)")
            }
        }

        // Sandbox restrictions on writes
        if sandboxLevel <= .sandbox && (toolName == "write" || toolName == "edit") {
            return .block(reason: "File write blocked in sandbox mode: \(path)")
        }

        return .allow
    }

    // MARK: - Stream Content Evaluation

    /// Check stream text content against blocked patterns.
    public func evaluateStreamContent(_ text: String, patterns: [NSRegularExpression]) -> PolicyDecision {
        let range = NSRange(text.startIndex..., in: text)
        for regex in patterns {
            if regex.firstMatch(in: text, range: range) != nil {
                return .warn(reason: "Stream content matched blocked pattern")
            }
        }
        return .allow
    }
}
