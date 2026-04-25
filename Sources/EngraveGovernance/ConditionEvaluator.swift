import Foundation

/// Evaluates condition expressions against a GovernanceContext.
///
/// Supported syntax:
/// - Numeric comparisons: `tokens_used > 50000`, `tokens_used >= tokens_budget * 0.8`
/// - String equality: `sandbox_level == "full"`, `model != "test"`
/// - Logical operators: `&&`, `||`, `!`
/// - Arithmetic: `+`, `-`, `*`, `/`
/// - Parentheses: `(tokens_used > 100) && (sandbox_level != "jailed")`
public struct ConditionEvaluator {

    public init() {}

    /// Evaluate a condition string against the given context.
    /// Returns true if the condition is met, false otherwise.
    /// Returns true for nil/empty conditions (always match).
    public func evaluate(_ condition: String?, context: GovernanceContext) -> Bool {
        guard let condition = condition, !condition.trimmingCharacters(in: .whitespaces).isEmpty else {
            return true
        }
        let tokens = tokenize(condition)
        var pos = 0
        return parseOr(tokens: tokens, pos: &pos, context: context)
    }

    // MARK: - Tokenizer

    private enum Token {
        case number(Double)
        case string(String)
        case identifier(String)
        case op(String)       // ==, !=, >, <, >=, <=, +, -, *, /
        case logicalAnd       // &&
        case logicalOr        // ||
        case logicalNot       // !
        case leftParen
        case rightParen
    }

    private func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var chars = Array(input)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }

            // Two-char operators
            if i + 1 < chars.count {
                let two = String(chars[i...i+1])
                switch two {
                case "&&": tokens.append(.logicalAnd); i += 2; continue
                case "||": tokens.append(.logicalOr); i += 2; continue
                case "==": tokens.append(.op("==")); i += 2; continue
                case "!=": tokens.append(.op("!=")); i += 2; continue
                case ">=": tokens.append(.op(">=")); i += 2; continue
                case "<=": tokens.append(.op("<=")); i += 2; continue
                default: break
                }
            }

            // Single-char operators
            switch c {
            case ">": tokens.append(.op(">")); i += 1; continue
            case "<": tokens.append(.op("<")); i += 1; continue
            case "+": tokens.append(.op("+")); i += 1; continue
            case "-":
                // Check if it's a negative number
                if i + 1 < chars.count && chars[i+1].isNumber {
                    let start = i; i += 1
                    while i < chars.count && (chars[i].isNumber || chars[i] == ".") { i += 1 }
                    if let num = Double(String(chars[start..<i])) { tokens.append(.number(num)) }
                    continue
                }
                tokens.append(.op("-")); i += 1; continue
            case "*": tokens.append(.op("*")); i += 1; continue
            case "/": tokens.append(.op("/")); i += 1; continue
            case "!": tokens.append(.logicalNot); i += 1; continue
            case "(": tokens.append(.leftParen); i += 1; continue
            case ")": tokens.append(.rightParen); i += 1; continue
            default: break
            }

            // String literal
            if c == "\"" {
                i += 1
                var str = ""
                while i < chars.count && chars[i] != "\"" {
                    if chars[i] == "\\" && i + 1 < chars.count { i += 1 }
                    str.append(chars[i]); i += 1
                }
                if i < chars.count { i += 1 } // skip closing quote
                tokens.append(.string(str))
                continue
            }

            // Number
            if c.isNumber {
                let start = i
                while i < chars.count && (chars[i].isNumber || chars[i] == ".") { i += 1 }
                if let num = Double(String(chars[start..<i])) { tokens.append(.number(num)) }
                continue
            }

            // Identifier (field name)
            if c.isLetter || c == "_" {
                let start = i
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") { i += 1 }
                tokens.append(.identifier(String(chars[start..<i])))
                continue
            }

            i += 1
        }
        return tokens
    }

    // MARK: - Recursive Descent Parser

    private func parseOr(tokens: [Token], pos: inout Int, context: GovernanceContext) -> Bool {
        var result = parseAnd(tokens: tokens, pos: &pos, context: context)
        while pos < tokens.count, case .logicalOr = tokens[pos] {
            pos += 1
            let right = parseAnd(tokens: tokens, pos: &pos, context: context)
            result = result || right
        }
        return result
    }

    private func parseAnd(tokens: [Token], pos: inout Int, context: GovernanceContext) -> Bool {
        var result = parseNot(tokens: tokens, pos: &pos, context: context)
        while pos < tokens.count, case .logicalAnd = tokens[pos] {
            pos += 1
            let right = parseNot(tokens: tokens, pos: &pos, context: context)
            result = result && right
        }
        return result
    }

    private func parseNot(tokens: [Token], pos: inout Int, context: GovernanceContext) -> Bool {
        if pos < tokens.count, case .logicalNot = tokens[pos] {
            pos += 1
            return !parseComparison(tokens: tokens, pos: &pos, context: context)
        }
        return parseComparison(tokens: tokens, pos: &pos, context: context)
    }

    private func parseComparison(tokens: [Token], pos: inout Int, context: GovernanceContext) -> Bool {
        // Check for parenthesized expression
        if pos < tokens.count, case .leftParen = tokens[pos] {
            pos += 1
            let result = parseOr(tokens: tokens, pos: &pos, context: context)
            if pos < tokens.count, case .rightParen = tokens[pos] { pos += 1 }
            return result
        }

        // Try string comparison first
        if let leftStr = parseStringValue(tokens: tokens, pos: &pos, context: context) {
            if pos < tokens.count, case .op(let op) = tokens[pos] {
                pos += 1
                if let rightStr = parseStringValue(tokens: tokens, pos: &pos, context: context) {
                    switch op {
                    case "==": return leftStr == rightStr
                    case "!=": return leftStr != rightStr
                    default: return false
                    }
                }
            }
            return !leftStr.isEmpty
        }

        // Numeric comparison
        let left = parseArithmetic(tokens: tokens, pos: &pos, context: context)
        guard pos < tokens.count, case .op(let op) = tokens[pos] else { return left != 0 }
        pos += 1
        let right = parseArithmetic(tokens: tokens, pos: &pos, context: context)

        switch op {
        case "==": return left == right
        case "!=": return left != right
        case ">": return left > right
        case "<": return left < right
        case ">=": return left >= right
        case "<=": return left <= right
        default: return false
        }
    }

    private func parseStringValue(tokens: [Token], pos: inout Int, context: GovernanceContext) -> String? {
        guard pos < tokens.count else { return nil }
        switch tokens[pos] {
        case .string(let s):
            pos += 1; return s
        case .identifier(let name):
            if let val = context.resolveStringField(name) {
                pos += 1; return val
            }
            return nil
        default: return nil
        }
    }

    private func parseArithmetic(tokens: [Token], pos: inout Int, context: GovernanceContext) -> Double {
        var result = parseTerm(tokens: tokens, pos: &pos, context: context)
        while pos < tokens.count, case .op(let op) = tokens[pos], op == "+" || op == "-" {
            pos += 1
            let right = parseTerm(tokens: tokens, pos: &pos, context: context)
            result = op == "+" ? result + right : result - right
        }
        return result
    }

    private func parseTerm(tokens: [Token], pos: inout Int, context: GovernanceContext) -> Double {
        var result = parsePrimary(tokens: tokens, pos: &pos, context: context)
        while pos < tokens.count, case .op(let op) = tokens[pos], op == "*" || op == "/" {
            pos += 1
            let right = parsePrimary(tokens: tokens, pos: &pos, context: context)
            result = op == "*" ? result * right : (right != 0 ? result / right : 0)
        }
        return result
    }

    private func parsePrimary(tokens: [Token], pos: inout Int, context: GovernanceContext) -> Double {
        guard pos < tokens.count else { return 0 }
        switch tokens[pos] {
        case .number(let n):
            pos += 1; return n
        case .identifier(let name):
            pos += 1; return context.resolveField(name) ?? 0
        case .leftParen:
            pos += 1
            let result = parseArithmetic(tokens: tokens, pos: &pos, context: context)
            if pos < tokens.count, case .rightParen = tokens[pos] { pos += 1 }
            return result
        default:
            pos += 1; return 0
        }
    }
}
