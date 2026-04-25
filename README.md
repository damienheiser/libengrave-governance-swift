# libengrave-ai-governance-swift

A native Swift governance engine for AI agent oversight. Provides declarative policy rules, tool call interception with risk classification, sandbox enforcement, and condition-based evaluation for controlling what AI agents can and cannot do.

Designed to work with [libengrave-ai-interposer-swift](https://github.com/damienheiser/libengrave-ai-interposer-swift) but can also be used independently for any AI agent governance scenario.

## What It Does

When an AI agent (Claude Code, Codex, Aider, etc.) makes a request through the Engrave interposer, the governance engine evaluates it against configured rules before the request reaches the backend. It can:

- **Block** requests that match dangerous patterns
- **Warn** on suspicious tool usage
- **Enforce sandbox levels** that restrict what tools can do
- **Classify tool calls** by risk level
- **Evaluate conditions** like token budgets and session state
- **Log all decisions** for audit

## Features

### Declarative Policy Rules

Define rules with triggers, severity levels, regex patterns, and conditions:

```swift
let rule = PolicyRule(
    name: "Block dangerous bash commands",
    trigger: .toolCall,
    severity: .block,
    matchPatterns: ["rm\\s+-rf", "sudo\\s+", "chmod\\s+777", "mkfs"],
    description: "Blocks bash commands that could damage the system"
)
```

**Rule Triggers:**
| Trigger | When Evaluated |
|---------|---------------|
| `.request` | On each incoming request before forwarding |
| `.response` | On completed response |
| `.toolCall` | When a tool use block is detected |
| `.streamEvent` | On each streaming SSE event |
| `.streamTextMatch` | When streamed text matches a pattern |

**Severity Levels:**
| Severity | Action |
|----------|--------|
| `.block` | Reject the request, return 403 |
| `.warn` | Allow but log a warning |
| `.modify` | Allow with field modifications |
| `.rewrite` | Replace response content |

**Built-in Rule Templates:**
- `PolicyRule.blockDangerousBash` -- blocks `rm -rf`, `sudo`, `chmod 777`, `mkfs`, `dd`
- `PolicyRule.blockSensitivePaths` -- blocks access to `.env`, `.ssh/`, `.aws/`, credentials
- `PolicyRule.warnExternalNetwork` -- warns on `curl`, `wget`, external HTTP requests
- `PolicyRule.warnLargeTokenUsage` -- warns when token usage exceeds 80% of budget

### Tool Interception

Classifies every tool call by risk level and enforces sandbox restrictions:

**Risk Classification:**
| Risk Level | Tools | Behavior |
|-----------|-------|----------|
| Safe | Read, Glob, Grep, ls, find | Always allowed |
| NeedsGovernance | Write, Edit, Bash, shell | Checked against sandbox level |
| Dangerous | rm, kill, sudo, chmod | Blocked unless full sandbox |

**What Gets Checked:**
- Tool name against risk classification
- File paths against blocked path patterns (regex)
- Bash commands against blocked command patterns (regex)
- Tool name against approval-required list
- Sandbox level restrictions on write operations

### Sandbox Levels

Four tiers of access control:

| Level | Read | Write | Bash | System |
|-------|:----:|:-----:|:----:|:------:|
| Jailed | No | No | No | No |
| Sandbox | Yes | No | Read-only | No |
| Workspace | Yes | Project dir | Restricted | No |
| Full | Yes | Yes | Yes | Yes |

### Condition Evaluator

Full expression parser for rule conditions:

```
tokens_used > tokens_budget * 0.8 && sandbox_level != "full"
```

**Supported Operations:**
- Numeric comparisons: `>`, `<`, `>=`, `<=`, `==`, `!=`
- String equality: `==`, `!=` (with quoted strings)
- Arithmetic: `+`, `-`, `*`, `/`
- Logical: `&&`, `||`, `!`
- Parentheses for grouping
- Field references: `tokens_used`, `tokens_budget`, `request_count`, `sandbox_level`, `model`, `agent_id`

### Governance Context

Tracks session state for condition evaluation:

```swift
var context = GovernanceContext(
    sessionId: "session-123",
    agentId: "claude-code",
    sandboxLevel: .workspace,
    tokensUsed: 45000,
    tokensBudget: 100000,
    model: "llama-3-8b",
    requestCount: 42
)
```

### Configuration Presets

Three built-in presets for common governance profiles:

| Preset | Sandbox | Rules | Use Case |
|--------|---------|-------|----------|
| Strict | Sandbox | Block dangerous bash, block sensitive paths, warn external network, warn token usage | Production, compliance |
| Standard | Workspace | Block dangerous bash, block sensitive paths | Everyday development |
| Minimal | Full | Warn token usage | Experimentation |

### Event Audit Log

Every governance decision is logged:

```swift
let events = await engine.recentEvents(count: 50)
for event in events {
    print("\(event.timestamp) \(event.decision) \(event.eventType) \(event.ruleName ?? "")")
}
```

Events include: timestamp, event type, rule name, decision, reason, model, session ID.

### Interposer Integration

The `GovernanceBridge` class adapts the `PolicyEngine` to the interposer's `GovernanceEvaluator` protocol:

```swift
let engine = PolicyEngine(config: governanceConfig)
let bridge = GovernanceBridge(engine: engine)
let engrave = Engrave(config: engraveConfig, governance: bridge)
```

When connected, the interposer calls governance evaluation:
1. **Pre-request** -- before forwarding to backend (can block with 403)
2. **Stream events** -- on each SSE text delta
3. **Tool calls** -- when tool use blocks are detected

## Requirements

- macOS 14.0+
- Swift 5.9+
- Depends on [libengrave-ai-interposer-swift](https://github.com/damienheiser/libengrave-ai-interposer-swift) for IR types

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/damienheiser/libengrave-ai-governance-swift.git", branch: "main"),
]

// In your target:
.product(name: "EngraveGovernance", package: "libengrave-ai-governance-swift")
```

This automatically pulls in `libengrave-ai-interposer-swift` as a transitive dependency.

## Usage

### Basic Setup

```swift
import EngraveGovernance

// Use a preset
let config = GovernanceConfig.standard

// Or build custom
var config = GovernanceConfig(
    enabled: true,
    sandboxLevel: .workspace,
    rules: [
        .blockDangerousBash,
        .blockSensitivePaths,
        PolicyRule(
            name: "Block SQL injection patterns",
            trigger: .request,
            severity: .block,
            matchPatterns: ["DROP\\s+TABLE", "DELETE\\s+FROM.*WHERE\\s+1=1"]
        ),
    ],
    blockedPaths: ["\\.env$", "\\.ssh/", "credentials"],
    blockedCommands: ["rm\\s+-rf", "sudo"],
    requireApprovalForTools: ["Bash", "Write"],
    maxTokensBudget: 100_000
)

let engine = PolicyEngine(config: config)
```

### Evaluate Requests

```swift
import EngraveInterposer

let request = CanonicalRequest(
    system: "You are a helpful assistant",
    messages: [CanonicalMessage(role: .user, content: [.text(TextBlock(text: "Delete all files"))])],
    model: "llama-3-8b"
)

let decision = await engine.evaluateRequest(request)
switch decision {
case .allow:
    print("Request allowed")
case .warn(let reason):
    print("Warning: \(reason)")
case .block(let reason):
    print("BLOCKED: \(reason)")
default:
    break
}
```

### Evaluate Tool Calls

```swift
let decision = await engine.evaluateToolCall(
    name: "Bash",
    input: ["command": "rm -rf /important/data"]
)
// -> .block(reason: "Blocked command pattern: rm -rf /important/data")
```

### With the Interposer

```swift
import EngraveInterposer
import EngraveGovernance

let govConfig = GovernanceConfig.strict
let engine = PolicyEngine(config: govConfig)
let bridge = GovernanceBridge(engine: engine)

let engraveConfig = EngraveConfig.forLocalMLX(model: "my-model", backendPort: 1234, proxyPort: 8900)
let engrave = Engrave(config: engraveConfig, governance: bridge)
try await engrave.start()

// Requests are now evaluated before forwarding:
// - Blocked requests return HTTP 403 with reason
// - Warnings are logged
// - Tool calls are classified and restricted by sandbox level
```

### Persistence

```swift
// Save
try config.save(to: "~/.config/mlx-launcher/governance.json")

// Load
let loaded = try GovernanceConfig.load(from: "~/.config/mlx-launcher/governance.json")
```

### Dynamic Updates

```swift
// Update config while running (takes effect on next request)
var newConfig = await engine.currentConfig
newConfig.sandboxLevel = .sandbox
newConfig.rules.append(PolicyRule(name: "New rule", severity: .block, matchPatterns: ["forbidden"]))
await engine.updateConfig(newConfig)
```

## API Reference

### Core Types
| Type | Description |
|------|-------------|
| `PolicyEngine` | Main evaluation engine (actor) |
| `PolicyRule` | Declarative rule with trigger, severity, patterns, conditions |
| `PolicyDecision` | `.allow`, `.warn`, `.block`, `.modify`, `.rewrite` |
| `GovernanceConfig` | Full configuration with rules, sandbox, blocked lists |
| `GovernanceContext` | Session state for condition evaluation |
| `GovernanceEvent` | Audit log entry |

### Evaluation
| Type | Description |
|------|-------------|
| `ToolInterceptor` | Tool risk classification and sandbox enforcement |
| `ConditionEvaluator` | Expression parser for rule conditions |
| `GovernanceBridge` | Adapts PolicyEngine to interposer's GovernanceEvaluator protocol |

### Enums
| Type | Values |
|------|--------|
| `SandboxLevel` | `.jailed`, `.sandbox`, `.workspace`, `.full` |
| `RuleTrigger` | `.request`, `.response`, `.toolCall`, `.streamEvent`, `.streamTextMatch` |
| `RuleSeverity` | `.block`, `.warn`, `.modify`, `.rewrite` |
| `ToolRisk` | `.safe`, `.needsGovernance`, `.dangerous` |

## Roadmap

Future additions planned:
- **Circuit breakers** -- 6 types (TokenBudget, RepeatedFailure, Stall, ScopeViolation, FileConflict, HealthDegradation) with 3-state FSM (closed/half-open/open)
- **Event log with Merkle DAG** -- append-only JSONL with SHA-256 content hashing for tamper-evident audit trails
- **Steering engine** -- pause, resume, redirect, reprioritize running agents
- **Quality gates** -- complexity-based review triggers

## License

MIT
