import Foundation

/// Configuration for the governance engine.
public struct GovernanceConfig: Codable, Sendable {
    public var enabled: Bool
    public var sandboxLevel: SandboxLevel
    public var rules: [PolicyRule]
    public var blockedPaths: [String]
    public var blockedCommands: [String]
    public var requireApprovalForTools: [String]
    public var maxTokensBudget: UInt32?
    public var eventLogPath: String?

    public init(
        enabled: Bool = false,
        sandboxLevel: SandboxLevel = .workspace,
        rules: [PolicyRule] = [],
        blockedPaths: [String] = [],
        blockedCommands: [String] = [],
        requireApprovalForTools: [String] = [],
        maxTokensBudget: UInt32? = nil,
        eventLogPath: String? = nil
    ) {
        self.enabled = enabled
        self.sandboxLevel = sandboxLevel
        self.rules = rules
        self.blockedPaths = blockedPaths
        self.blockedCommands = blockedCommands
        self.requireApprovalForTools = requireApprovalForTools
        self.maxTokensBudget = maxTokensBudget
        self.eventLogPath = eventLogPath
    }

    // MARK: - Presets

    /// Strict governance: blocks dangerous ops, warns on writes, full audit
    public static let strict = GovernanceConfig(
        enabled: true,
        sandboxLevel: .sandbox,
        rules: [
            .blockDangerousBash,
            .blockSensitivePaths,
            .warnExternalNetwork,
            .warnLargeTokenUsage,
        ],
        blockedPaths: ["\\.env$", "credentials", "\\.ssh/", "\\.aws/", "secrets\\."],
        blockedCommands: ["rm\\s+-rf", "sudo\\s+", "chmod\\s+777"],
        requireApprovalForTools: ["Bash"],
        maxTokensBudget: 100_000
    )

    /// Standard governance: balanced safety
    public static let standard = GovernanceConfig(
        enabled: true,
        sandboxLevel: .workspace,
        rules: [
            .blockDangerousBash,
            .blockSensitivePaths,
        ],
        blockedPaths: ["\\.env$", "\\.ssh/"],
        blockedCommands: ["rm\\s+-rf", "sudo\\s+"]
    )

    /// Minimal: monitoring only
    public static let minimal = GovernanceConfig(
        enabled: true,
        sandboxLevel: .full,
        rules: [.warnLargeTokenUsage]
    )

    // MARK: - Persistence

    public static func load(from path: String) throws -> GovernanceConfig {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GovernanceConfig.self, from: data)
    }

    public func save(to path: String) throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url)
    }
}
