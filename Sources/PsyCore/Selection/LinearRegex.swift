import Foundation

/// A deliberately bounded, RE2-compatible subset implemented as a Thompson NFA.
/// Matching never calls ICU and takes O(input scalars * compiled states) time.
struct LinearRegexProgram: Sendable {
    private static let maximumCompiledStates = 4_096

    private let instructions: [LinearRegexInstruction]
    private let start: Int
    private let caseInsensitive: Bool

    init(pattern: String, caseInsensitive: Bool = false) throws {
        var parser = LinearRegexParser(pattern: pattern)
        let expression = try parser.parse()
        var compiler = LinearRegexCompiler(
            maximumStates: Self.maximumCompiledStates,
            caseInsensitive: caseInsensitive
        )
        let compiled = try compiler.compile(expression)
        instructions = compiled.instructions
        start = compiled.start
        self.caseInsensitive = caseInsensitive
    }

    func matches(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.map(\.value)
        var position = 0
        var active = epsilonClosure(seeds: [start], position: position, scalars: scalars)

        while true {
            if active.contains(where: isAccepting) { return true }
            guard position < scalars.count else { return false }

            let scalar = scalars[position]
            let caseFold = caseInsensitive ? LinearRegexCaseFold(scalar) : nil
            var seeds: [Int] = []
            seeds.reserveCapacity(active.count + 1)
            for state in active {
                guard case .consume(let matcher, let next) = instructions[state],
                    matcher.matches(scalar, caseFold: caseFold)
                else { continue }
                seeds.append(next)
            }

            position += 1
            // Starting the NFA at every scalar boundary gives RE2's unanchored
            // search semantics without a backtracking `.*?` prefix.
            seeds.append(start)
            active = epsilonClosure(seeds: seeds, position: position, scalars: scalars)
        }
    }

    private func epsilonClosure(seeds: [Int], position: Int, scalars: [UInt32]) -> [Int] {
        var stack = seeds
        var visited = [Bool](repeating: false, count: instructions.count)
        var consumingOrAccepting: [Int] = []

        while let state = stack.popLast() {
            guard !visited[state] else { continue }
            visited[state] = true
            switch instructions[state] {
            case .accept, .consume:
                consumingOrAccepting.append(state)
            case .split(let first, let second):
                stack.append(second)
                stack.append(first)
            case .assertion(let assertion, let next):
                if assertion.matches(position: position, scalars: scalars) {
                    stack.append(next)
                }
            }
        }
        return consumingOrAccepting
    }

    private func isAccepting(_ state: Int) -> Bool {
        if case .accept = instructions[state] { return true }
        return false
    }
}

private indirect enum LinearRegexNode: Sendable {
    case empty
    case scalar(UInt32)
    case anyScalarExceptNewline
    case characterClass(LinearRegexCharacterClass)
    case assertion(LinearRegexAssertion)
    case concatenation([LinearRegexNode])
    case alternation([LinearRegexNode])
    case repetition(LinearRegexNode, minimum: Int, maximum: Int?)
}

private enum LinearRegexInstruction: Sendable {
    case accept
    case consume(LinearRegexMatcher, next: Int)
    case split(Int, Int)
    case assertion(LinearRegexAssertion, next: Int)
}

private enum LinearRegexMatcher: Sendable {
    case scalar(UInt32, foldedKey: String?)
    case anyScalarExceptNewline
    case characterClass(LinearRegexCharacterClass)

    func matches(_ candidate: UInt32, caseFold: LinearRegexCaseFold?) -> Bool {
        switch self {
        case .scalar(let expected, let foldedKey):
            guard let foldedKey, let caseFold else { return candidate == expected }
            return caseFold.key == foldedKey
        case .anyScalarExceptNewline: return candidate != 0x0A
        case .characterClass(let characterClass):
            return characterClass.matches(candidate, caseFold: caseFold)
        }
    }
}

private enum LinearRegexAssertion: Sendable {
    case startOfText
    case endOfText
    case asciiWordBoundary
    case notASCIIWordBoundary

    func matches(position: Int, scalars: [UInt32]) -> Bool {
        switch self {
        case .startOfText:
            return position == 0
        case .endOfText:
            return position == scalars.count
        case .asciiWordBoundary, .notASCIIWordBoundary:
            let leftIsWord = position > 0 && LinearRegexPredefinedClass.asciiWord.matches(scalars[position - 1])
            let rightIsWord =
                position < scalars.count
                && LinearRegexPredefinedClass.asciiWord.matches(scalars[position])
            let isBoundary = leftIsWord != rightIsWord
            return self == .asciiWordBoundary ? isBoundary : !isBoundary
        }
    }
}

private struct LinearRegexCharacterClass: Sendable {
    enum Component: Sendable {
        case range(ClosedRange<UInt32>)
        case predefined(LinearRegexPredefinedClass, inverted: Bool)

        func matches(_ candidate: UInt32, caseFold: LinearRegexCaseFold?) -> Bool {
            switch self {
            case .range(let range):
                guard let caseFold else { return range.contains(candidate) }
                if caseFold.scalarVariants.contains(where: range.contains) { return true }
                if range.lowerBound == range.upperBound {
                    return caseFold.key == linearRegexCaseFoldKey(range.lowerBound)
                }
                return false
            case .predefined(let predefined, let inverted):
                return inverted ? !predefined.matches(candidate) : predefined.matches(candidate)
            }
        }
    }

    let negated: Bool
    let components: [Component]

    func matches(_ candidate: UInt32, caseFold: LinearRegexCaseFold?) -> Bool {
        let matched = components.contains { $0.matches(candidate, caseFold: caseFold) }
        return negated ? !matched : matched
    }
}

private enum LinearRegexPredefinedClass: Sendable {
    case asciiDigit
    case asciiSpace
    case asciiWord

    func matches(_ candidate: UInt32) -> Bool {
        switch self {
        case .asciiDigit:
            (0x30...0x39).contains(candidate)
        case .asciiSpace:
            candidate == 0x09 || candidate == 0x0A || candidate == 0x0C || candidate == 0x0D
                || candidate == 0x20
        case .asciiWord:
            (0x30...0x39).contains(candidate) || (0x41...0x5A).contains(candidate)
                || candidate == 0x5F || (0x61...0x7A).contains(candidate)
        }
    }
}

private struct LinearRegexCaseFold: Sendable {
    let key: String
    let scalarVariants: [UInt32]

    init(_ value: UInt32) {
        key = linearRegexCaseFoldKey(value)
        var variants = [value]
        var seen: Set<UInt32> = [value]
        var cursor = 0
        while cursor < variants.count, variants.count < 16 {
            guard let scalar = Unicode.Scalar(variants[cursor]) else { break }
            let properties = scalar.properties
            for mapping in [
                properties.lowercaseMapping,
                properties.uppercaseMapping,
                properties.titlecaseMapping,
            ] {
                let mapped = Array(mapping.unicodeScalars)
                guard mapped.count == 1, seen.insert(mapped[0].value).inserted else { continue }
                variants.append(mapped[0].value)
            }
            cursor += 1
        }
        scalarVariants = variants
    }
}

private let linearRegexCaseFoldLocale = Locale(identifier: "en_US_POSIX")

private func linearRegexCaseFoldKey(_ value: UInt32) -> String {
    guard let scalar = Unicode.Scalar(value) else { return "" }
    return String(scalar).folding(
        options: [.caseInsensitive, .literal],
        locale: linearRegexCaseFoldLocale
    )
}

private struct LinearRegexCompiler {
    let maximumStates: Int
    let caseInsensitive: Bool
    private(set) var instructions: [LinearRegexInstruction] = []
    private var expansionSteps = 0

    init(maximumStates: Int, caseInsensitive: Bool) {
        self.maximumStates = maximumStates
        self.caseInsensitive = caseInsensitive
    }

    mutating func compile(
        _ expression: LinearRegexNode
    ) throws -> (instructions: [LinearRegexInstruction], start: Int) {
        let accept = try append(.accept)
        let start = try emit(expression, next: accept)
        return (instructions, start)
    }

    private mutating func emit(_ node: LinearRegexNode, next: Int) throws -> Int {
        expansionSteps += 1
        guard expansionSteps <= maximumStates * 4 else {
            throw RuleValidationError.unsafeRegex(
                "compiled expression exceeds 16384 expansion steps"
            )
        }
        switch node {
        case .empty:
            return next
        case .scalar(let scalar):
            let foldedKey = caseInsensitive ? linearRegexCaseFoldKey(scalar) : nil
            return try append(.consume(.scalar(scalar, foldedKey: foldedKey), next: next))
        case .anyScalarExceptNewline:
            return try append(.consume(.anyScalarExceptNewline, next: next))
        case .characterClass(let characterClass):
            return try append(.consume(.characterClass(characterClass), next: next))
        case .assertion(let assertion):
            return try append(.assertion(assertion, next: next))
        case .concatenation(let nodes):
            var start = next
            for child in nodes.reversed() {
                start = try emit(child, next: start)
            }
            return start
        case .alternation(let alternatives):
            guard let last = alternatives.last else { return next }
            var combined = try emit(last, next: next)
            for alternative in alternatives.dropLast().reversed() {
                let alternativeStart = try emit(alternative, next: next)
                combined = try append(.split(alternativeStart, combined))
            }
            return combined
        case .repetition(let repeated, let minimum, let maximum):
            var start: Int
            if let maximum {
                start = next
                for _ in 0..<(maximum - minimum) {
                    start = try emitOptional(repeated, next: start)
                }
            } else {
                start = try emitZeroOrMore(repeated, next: next)
            }
            for _ in 0..<minimum {
                start = try emit(repeated, next: start)
            }
            return start
        }
    }

    private mutating func emitOptional(_ node: LinearRegexNode, next: Int) throws -> Int {
        let included = try emit(node, next: next)
        return try append(.split(included, next))
    }

    private mutating func emitZeroOrMore(_ node: LinearRegexNode, next: Int) throws -> Int {
        let split = try append(.split(next, next))
        let repeated = try emit(node, next: split)
        instructions[split] = .split(repeated, next)
        return split
    }

    private mutating func append(_ instruction: LinearRegexInstruction) throws -> Int {
        guard instructions.count < maximumStates else {
            throw RuleValidationError.unsafeRegex("compiled expression exceeds 4096 states")
        }
        instructions.append(instruction)
        return instructions.count - 1
    }
}

private struct LinearRegexParser {
    private static let maximumGroupDepth = 64
    private static let maximumCountedRepetition = 1_000

    private let scalars: [Unicode.Scalar]
    private var index = 0
    private var groupDepth = 0

    init(pattern: String) {
        scalars = Array(pattern.unicodeScalars)
    }

    mutating func parse() throws -> LinearRegexNode {
        let expression = try parseAlternation()
        guard isAtEnd else {
            if peek() == ")" { throw RuleValidationError.invalidRegex("unmatched closing parenthesis") }
            throw RuleValidationError.invalidRegex("unexpected token")
        }
        return expression
    }

    private mutating func parseAlternation() throws -> LinearRegexNode {
        var alternatives = [try parseConcatenation()]
        while consume("|") {
            alternatives.append(try parseConcatenation())
        }
        return alternatives.count == 1 ? alternatives[0] : .alternation(alternatives)
    }

    private mutating func parseConcatenation() throws -> LinearRegexNode {
        var nodes: [LinearRegexNode] = []
        while let scalar = peek(), scalar != "|", scalar != ")" {
            nodes.append(try parseRepetition())
        }
        if nodes.isEmpty { return .empty }
        return nodes.count == 1 ? nodes[0] : .concatenation(nodes)
    }

    private mutating func parseRepetition() throws -> LinearRegexNode {
        let atom = try parseAtom()
        let limits: (minimum: Int, maximum: Int?)?
        switch peek() {
        case "*":
            advance()
            limits = (0, nil)
        case "+":
            advance()
            limits = (1, nil)
        case "?":
            advance()
            limits = (0, 1)
        case "{":
            limits = try parseCountedRepetition()
        default:
            limits = nil
        }
        guard let limits else { return atom }

        if case .assertion = atom {
            throw RuleValidationError.invalidRegex("zero-width assertion cannot be repeated")
        }

        // RE2's lazy suffix changes match preference, not whether a match exists.
        _ = consume("?")
        if let scalar = peek(), scalar == "*" || scalar == "+" || scalar == "?" || scalar == "{" {
            throw RuleValidationError.unsafeRegex("stacked quantifiers are rejected")
        }
        return .repetition(atom, minimum: limits.minimum, maximum: limits.maximum)
    }

    private mutating func parseAtom() throws -> LinearRegexNode {
        guard let scalar = advance() else { return .empty }
        switch scalar {
        case ".":
            return .anyScalarExceptNewline
        case "^":
            return .assertion(.startOfText)
        case "$":
            return .assertion(.endOfText)
        case "(":
            if peek() == "?" { throw unsupportedGroupExtension() }
            groupDepth += 1
            guard groupDepth <= Self.maximumGroupDepth else {
                throw RuleValidationError.unsafeRegex("group nesting exceeds 64 levels")
            }
            defer { groupDepth -= 1 }
            let expression = try parseAlternation()
            guard consume(")") else { throw RuleValidationError.invalidRegex("unterminated group") }
            return expression
        case "[":
            return .characterClass(try parseCharacterClass())
        case "\\":
            return try node(for: parseEscape(inCharacterClass: false))
        case "*", "+", "?", "{":
            throw RuleValidationError.invalidRegex("repetition operator has no operand")
        case ")":
            throw RuleValidationError.invalidRegex("unmatched closing parenthesis")
        case "}":
            throw RuleValidationError.invalidRegex("unescaped closing brace")
        default:
            return .scalar(scalar.value)
        }
    }

    private mutating func parseCountedRepetition() throws -> (minimum: Int, maximum: Int?) {
        precondition(consume("{"))
        guard peek()?.isASCIIDigit == true else {
            throw RuleValidationError.invalidRegex("counted repetition is missing its lower bound")
        }
        let minimum = try parseDecimalCount()
        if consume("}") { return (minimum, minimum) }
        guard consume(",") else {
            throw RuleValidationError.invalidRegex("invalid counted repetition")
        }
        if consume("}") { return (minimum, nil) }
        guard peek()?.isASCIIDigit == true else {
            throw RuleValidationError.invalidRegex("counted repetition is missing its upper bound")
        }
        let maximum = try parseDecimalCount()
        guard consume("}") else {
            throw RuleValidationError.invalidRegex("unterminated counted repetition")
        }
        guard maximum >= minimum else {
            throw RuleValidationError.invalidRegex("counted repetition upper bound is below lower bound")
        }
        return (minimum, maximum)
    }

    private mutating func parseDecimalCount() throws -> Int {
        var value = 0
        while let scalar = peek(), scalar.isASCIIDigit {
            advance()
            value = value * 10 + Int(scalar.value - 0x30)
            guard value <= Self.maximumCountedRepetition else {
                throw RuleValidationError.unsupportedRegexFeature("counted repetition above 1000")
            }
        }
        return value
    }

    private mutating func parseCharacterClass() throws -> LinearRegexCharacterClass {
        let negated = consume("^")
        var components: [LinearRegexCharacterClass.Component] = []
        var sawElement = false

        while let scalar = peek() {
            if scalar == "]" {
                guard sawElement else {
                    throw RuleValidationError.invalidRegex("empty character class")
                }
                advance()
                return LinearRegexCharacterClass(negated: negated, components: components)
            }
            if scalar == "[" {
                throw RuleValidationError.unsupportedRegexFeature("nested or POSIX character class")
            }

            let wasFirstElement = !sawElement
            let left = try parseClassAtom()
            sawElement = true
            if case .scalar(let value) = left, value == 0x2D, wasFirstElement {
                components.append(.range(value...value))
                continue
            }

            if peek() == "-", peek(offset: 1) != "]" {
                advance()
                guard case .scalar(let lower) = left,
                    case .scalar(let upper) = try parseClassAtom()
                else {
                    throw RuleValidationError.invalidRegex(
                        "character class range endpoints must be literals"
                    )
                }
                guard lower <= upper else {
                    throw RuleValidationError.invalidRegex("character class range is reversed")
                }
                components.append(.range(lower...upper))
            } else {
                components.append(left.component)
            }
        }
        throw RuleValidationError.invalidRegex("unterminated character class")
    }

    private mutating func parseClassAtom() throws -> LinearRegexClassAtom {
        guard let scalar = advance() else {
            throw RuleValidationError.invalidRegex("unterminated character class")
        }
        if scalar == "\\" {
            switch try parseEscape(inCharacterClass: true) {
            case .scalar(let value): return .scalar(value)
            case .predefined(let predefined, let inverted):
                return .predefined(predefined, inverted: inverted)
            case .assertion:
                throw RuleValidationError.invalidRegex("zero-width escape in character class")
            }
        }
        return .scalar(scalar.value)
    }

    private mutating func parseEscape(inCharacterClass: Bool) throws -> LinearRegexEscape {
        guard let escaped = advance() else {
            throw RuleValidationError.invalidRegex("trailing escape")
        }
        switch escaped {
        case "a": return .scalar(0x07)
        case "f": return .scalar(0x0C)
        case "n": return .scalar(0x0A)
        case "r": return .scalar(0x0D)
        case "t": return .scalar(0x09)
        case "v": return .scalar(0x0B)
        case "d": return .predefined(.asciiDigit, inverted: false)
        case "D": return .predefined(.asciiDigit, inverted: true)
        case "s": return .predefined(.asciiSpace, inverted: false)
        case "S": return .predefined(.asciiSpace, inverted: true)
        case "w": return .predefined(.asciiWord, inverted: false)
        case "W": return .predefined(.asciiWord, inverted: true)
        case "b":
            return inCharacterClass ? .scalar(0x08) : .assertion(.asciiWordBoundary)
        case "B":
            guard !inCharacterClass else {
                throw RuleValidationError.invalidRegex("zero-width escape in character class")
            }
            return .assertion(.notASCIIWordBoundary)
        case "A":
            guard !inCharacterClass else {
                throw RuleValidationError.invalidRegex("zero-width escape in character class")
            }
            return .assertion(.startOfText)
        case "z":
            guard !inCharacterClass else {
                throw RuleValidationError.invalidRegex("zero-width escape in character class")
            }
            return .assertion(.endOfText)
        case "x":
            return .scalar(try parseHexEscape())
        case "1"..."9":
            throw RuleValidationError.unsupportedRegexFeature("backreference")
        case "0":
            throw RuleValidationError.unsupportedRegexFeature("octal escape")
        case "k" where peek() == "<":
            throw RuleValidationError.unsupportedRegexFeature("named backreference")
        case "p", "P":
            throw RuleValidationError.unsupportedRegexFeature("Unicode character class")
        case "Q":
            throw RuleValidationError.unsupportedRegexFeature("quoted literal block")
        case "C":
            throw RuleValidationError.unsupportedRegexFeature("single-byte matcher")
        default:
            if escaped.value < 0x80, !escaped.isASCIIAlphaNumeric {
                return .scalar(escaped.value)
            }
            throw RuleValidationError.unsupportedRegexFeature("escape \\\(escaped)")
        }
    }

    private mutating func parseHexEscape() throws -> UInt32 {
        var value: UInt32 = 0
        if consume("{") {
            var digitCount = 0
            while let scalar = peek(), let digit = scalar.hexValue {
                advance()
                digitCount += 1
                guard digitCount <= 6 else {
                    throw RuleValidationError.invalidRegex("hex escape is too long")
                }
                value = value * 16 + digit
            }
            guard digitCount > 0, consume("}") else {
                throw RuleValidationError.invalidRegex("invalid braced hex escape")
            }
        } else {
            for _ in 0..<2 {
                guard let scalar = advance(), let digit = scalar.hexValue else {
                    throw RuleValidationError.invalidRegex("hex escape requires two digits")
                }
                value = value * 16 + digit
            }
        }
        guard value <= 0x10_FFFF, !(0xD800...0xDFFF).contains(value) else {
            throw RuleValidationError.invalidRegex("hex escape is not a Unicode scalar")
        }
        return value
    }

    private func node(for escape: LinearRegexEscape) throws -> LinearRegexNode {
        switch escape {
        case .scalar(let scalar): return .scalar(scalar)
        case .predefined(let predefined, let inverted):
            return .characterClass(
                LinearRegexCharacterClass(
                    negated: false,
                    components: [.predefined(predefined, inverted: inverted)]
                )
            )
        case .assertion(let assertion): return .assertion(assertion)
        }
    }

    private func unsupportedGroupExtension() -> RuleValidationError {
        let feature: String
        if hasPrefix("?<=") {
            feature = "positive lookbehind"
        } else if hasPrefix("?<!") {
            feature = "negative lookbehind"
        } else if hasPrefix("?=") {
            feature = "positive lookahead"
        } else if hasPrefix("?!") {
            feature = "negative lookahead"
        } else if hasPrefix("?P<") || hasPrefix("?<") {
            feature = "named capture"
        } else if hasPrefix("?>") {
            feature = "atomic group"
        } else if hasPrefix("?(") {
            feature = "conditional expression"
        } else {
            feature = "group extension"
        }
        return .unsupportedRegexFeature(feature)
    }

    private var isAtEnd: Bool { index == scalars.count }

    private func peek(offset: Int = 0) -> Unicode.Scalar? {
        let candidate = index + offset
        guard scalars.indices.contains(candidate) else { return nil }
        return scalars[candidate]
    }

    @discardableResult
    private mutating func advance() -> Unicode.Scalar? {
        guard !isAtEnd else { return nil }
        defer { index += 1 }
        return scalars[index]
    }

    @discardableResult
    private mutating func consume(_ expected: Unicode.Scalar) -> Bool {
        guard peek() == expected else { return false }
        index += 1
        return true
    }

    private func hasPrefix(_ prefix: String) -> Bool {
        let prefixScalars = Array(prefix.unicodeScalars)
        guard index + prefixScalars.count <= scalars.count else { return false }
        return Array(scalars[index..<(index + prefixScalars.count)]) == prefixScalars
    }
}

private enum LinearRegexEscape {
    case scalar(UInt32)
    case predefined(LinearRegexPredefinedClass, inverted: Bool)
    case assertion(LinearRegexAssertion)
}

private enum LinearRegexClassAtom {
    case scalar(UInt32)
    case predefined(LinearRegexPredefinedClass, inverted: Bool)

    var component: LinearRegexCharacterClass.Component {
        switch self {
        case .scalar(let scalar): .range(scalar...scalar)
        case .predefined(let predefined, let inverted):
            .predefined(predefined, inverted: inverted)
        }
    }
}

extension Unicode.Scalar {
    fileprivate var isASCIIDigit: Bool { (0x30...0x39).contains(value) }

    fileprivate var isASCIIAlphaNumeric: Bool {
        isASCIIDigit || (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
    }

    fileprivate var hexValue: UInt32? {
        switch value {
        case 0x30...0x39: value - 0x30
        case 0x41...0x46: value - 0x41 + 10
        case 0x61...0x66: value - 0x61 + 10
        default: nil
        }
    }
}
