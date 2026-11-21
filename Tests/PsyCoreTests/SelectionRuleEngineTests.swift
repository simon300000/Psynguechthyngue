import Foundation
import XCTest

@testable import PsyCore

final class SelectionRuleEngineTests: XCTestCase {
    private let engine = SelectionRuleEngine()
    private let folder = FolderID(rawValue: "documents")!

    func testDoubleStarGlobCrossesDirectories() throws {
        let rule = SelectionRule(syntax: .syncthingGlob, action: .exclude, pattern: "**/*.tmp")
        XCTAssertEqual(
            try engine.evaluate(path: "a/b/cache.tmp", isDirectory: false, rules: [rule]).action,
            .exclude
        )
    }

    func testUnrootedSingleStarMatchesAtAnyDepthButDoesNotConsumeASeparator() throws {
        let rule = SelectionRule(syntax: .syncthingGlob, action: .exclude, pattern: "te*ne")
        XCTAssertEqual(
            try engine.evaluate(path: "a/telephone", isDirectory: false, rules: [rule]).action,
            .exclude
        )
        XCTAssertEqual(
            try engine.evaluate(path: "tele/phone", isDirectory: false, rules: [rule]).action,
            .include
        )
    }

    func testRootedPatternOnlyMatchesAtFolderRoot() throws {
        let rule = SelectionRule(syntax: .syncthingGlob, action: .exclude, pattern: "/foo")
        XCTAssertEqual(try engine.evaluate(path: "foo", isDirectory: false, rules: [rule]).action, .exclude)
        XCTAssertEqual(
            try engine.evaluate(path: "nested/foo", isDirectory: false, rules: [rule]).action,
            .include
        )
    }

    func testDirectorySlashMatchesContentsButNotDirectoryEntryItself() throws {
        let rule = SelectionRule(syntax: .syncthingGlob, action: .exclude, pattern: "some/directory/")
        XCTAssertEqual(
            try engine.evaluate(path: "some/directory", isDirectory: true, rules: [rule]).action,
            .include
        )
        XCTAssertEqual(
            try engine.evaluate(path: "some/directory/file.txt", isDirectory: false, rules: [rule]).action,
            .exclude
        )
    }

    func testOfficialCaseFoldAndBraceAlternatives() throws {
        let rule = SelectionRule(
            syntax: .syncthingGlob,
            action: .exclude,
            pattern: "(?i){banana,pineapple}.JPG"
        )
        XCTAssertEqual(
            try engine.evaluate(path: "fruit/BANANA.jpg", isDirectory: false, rules: [rule]).action,
            .exclude
        )
        XCTAssertEqual(
            try engine.evaluate(path: "fruit/apple.jpg", isDirectory: false, rules: [rule]).action,
            .include
        )
    }

    func testGlobCaseFoldingPreservesUnicodeScalarAndNegativeClassSemantics() throws {
        let literals = SelectionRule(
            syntax: .syncthingGlob,
            action: .exclude,
            pattern: "(?i)/Σ/ẞ.txt"
        )
        XCTAssertEqual(
            try engine.evaluate(path: "ς/ß.TXT", isDirectory: false, rules: [literals]).action,
            .exclude
        )

        let classes = SelectionRule(
            syntax: .syncthingGlob,
            action: .exclude,
            pattern: "(?i)/[α-ω][Σ].txt"
        )
        XCTAssertEqual(
            try engine.evaluate(path: "Βς.TXT", isDirectory: false, rules: [classes]).action,
            .exclude
        )

        let negative = SelectionRule(
            syntax: .syncthingGlob,
            action: .exclude,
            pattern: "(?i)/[^a].txt"
        )
        XCTAssertEqual(
            try engine.evaluate(path: "A.txt", isDirectory: false, rules: [negative]).action,
            .include
        )
        XCTAssertEqual(
            try engine.evaluate(path: "B.txt", isDirectory: false, rules: [negative]).action,
            .exclude
        )
    }

    func testGeneratedGlobProgramsRemainBoundedForAmbiguousStarsAndBraces() throws {
        let stars = SelectionRule(
            syntax: .syncthingGlob,
            action: .exclude,
            pattern: String(repeating: "**a", count: 24) + "b"
        )
        let braces = SelectionRule(
            syntax: .syncthingGlob,
            action: .exclude,
            pattern: String(repeating: "{a,aa}", count: 24) + "b"
        )

        let startedAt = Date()
        XCTAssertEqual(
            try engine.evaluate(
                path: String(repeating: "a", count: 2_000) + "!",
                isDirectory: false,
                rules: [stars]
            ).action,
            .include
        )
        XCTAssertEqual(
            try engine.evaluate(
                path: String(repeating: "a", count: 48) + "!",
                isDirectory: false,
                rules: [braces]
            ).action,
            .include
        )
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testEscapedGlobMetacharactersRemainLiteral() throws {
        let rule = SelectionRule(
            syntax: .syncthingGlob,
            action: .exclude,
            pattern: #"/literal\{name\}.txt"#
        )
        XCTAssertEqual(
            try engine.evaluate(path: "literal{name}.txt", isDirectory: false, rules: [rule]).action,
            .exclude
        )
    }

    func testFirstMatchingRuleWins() throws {
        let include = SelectionRule(syntax: .syncthingGlob, action: .include, pattern: "keep/**")
        let exclude = SelectionRule(syntax: .syncthingGlob, action: .exclude, pattern: "**")
        XCTAssertEqual(
            try engine.evaluate(path: "keep/new/file.txt", isDirectory: false, rules: [include, exclude]).action,
            .include
        )
    }

    func testDisabledRuleIsSkipped() throws {
        let rule = SelectionRule(
            syntax: .syncthingGlob,
            action: .exclude,
            pattern: "**",
            isEnabled: false
        )
        XCTAssertEqual(try engine.evaluate(path: "a", isDirectory: false, rules: [rule]).action, .include)
    }

    func testBackreferenceIsRejected() {
        let rule = SelectionRule(syntax: .re2SafeRegex, action: .exclude, pattern: #"^(a+)\1$"#)
        guard case .failure(let error) = engine.validate(rule) else {
            return XCTFail("Expected validation failure")
        }
        XCTAssertEqual(error, .unsupportedRegexFeature("backreference"))
    }

    func testAmbiguousAlternationRepeatRunsInLinearTime() throws {
        let rule = SelectionRule(syntax: .re2SafeRegex, action: .exclude, pattern: #"^(a|aa)+$"#)
        let path = String(repeating: "a", count: 20_000) + "!"

        let startedAt = Date()
        XCTAssertEqual(try engine.evaluate(path: path, isDirectory: false, rules: [rule]).action, .include)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testNestedUnboundedRepeatRunsInLinearTime() throws {
        let rule = SelectionRule(syntax: .re2SafeRegex, action: .exclude, pattern: #"^(a+)+$"#)
        let path = String(repeating: "a", count: 20_000) + "!"

        let startedAt = Date()
        XCTAssertEqual(try engine.evaluate(path: path, isDirectory: false, rules: [rule]).action, .include)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testRegexSupportsGroupsAlternationClassesAnchorsAndCommonQuantifiers() throws {
        let rule = SelectionRule(
            syntax: .re2SafeRegex,
            action: .exclude,
            pattern: #"^(docs|notes)/[A-Za-z0-9_]+(\.(txt|md))?$"#
        )
        XCTAssertEqual(
            try engine.evaluate(path: "docs/report_2.txt", isDirectory: false, rules: [rule]).action,
            .exclude
        )
        XCTAssertEqual(
            try engine.evaluate(path: "archive/docs/report_2.txt", isDirectory: false, rules: [rule]).action,
            .include
        )
        XCTAssertEqual(
            try engine.evaluate(path: "notes/readme", isDirectory: false, rules: [rule]).action,
            .exclude
        )
    }

    func testRegexSupportsBoundedAndUnboundedCounts() throws {
        let bounded = SelectionRule(
            syntax: .re2SafeRegex,
            action: .exclude,
            pattern: #"^part-[0-9]{2,4}$"#
        )
        let unbounded = SelectionRule(
            syntax: .re2SafeRegex,
            action: .exclude,
            pattern: #"^part-[0-9]{2,}$"#
        )
        XCTAssertEqual(
            try engine.evaluate(path: "part-123", isDirectory: false, rules: [bounded]).action,
            .exclude
        )
        XCTAssertEqual(
            try engine.evaluate(path: "part-12345", isDirectory: false, rules: [bounded]).action,
            .include
        )
        XCTAssertEqual(
            try engine.evaluate(path: "part-12345", isDirectory: false, rules: [unbounded]).action,
            .exclude
        )
    }

    func testRegexMatchesUnicodeScalarsAndPathSeparatorsDeterministically() throws {
        let rule = SelectionRule(
            syntax: .re2SafeRegex,
            action: .exclude,
            pattern: #"^资料/[猫狗]+-[α-ω]{2,4}\.txt$"#
        )
        XCTAssertEqual(
            try engine.evaluate(path: "资料/猫狗-αβγ.txt", isDirectory: false, rules: [rule]).action,
            .exclude
        )
        XCTAssertEqual(
            try engine.evaluate(path: "资料/猫/狗-αβ.txt", isDirectory: false, rules: [rule]).action,
            .include
        )
    }

    func testRegexDotDoesNotMatchNewline() throws {
        let rule = SelectionRule(syntax: .re2SafeRegex, action: .exclude, pattern: #"^a.b$"#)
        XCTAssertEqual(
            try engine.evaluate(path: "a\nb", isDirectory: false, rules: [rule]).action,
            .include
        )
    }

    func testUnsupportedGroupExtensionFailsClosed() {
        let rule = SelectionRule(syntax: .re2SafeRegex, action: .exclude, pattern: #"(?i)^notes/"#)
        guard case .failure(let error) = engine.validate(rule) else {
            return XCTFail("Expected validation failure")
        }
        XCTAssertEqual(error, .unsupportedRegexFeature("group extension"))
    }

    func testOversizedCompiledExpressionFailsClosed() {
        let atom = String(repeating: "a", count: 16)
        let rule = SelectionRule(
            syntax: .re2SafeRegex,
            action: .exclude,
            pattern: "(\(atom)){300}"
        )
        guard case .failure(let error) = engine.validate(rule) else {
            return XCTFail("Expected validation failure")
        }
        XCTAssertEqual(error, .unsafeRegex("compiled expression exceeds 4096 states"))
    }

    func testNestedEmptyCountsCannotBypassCompilationComplexityLimit() {
        let rule = SelectionRule(
            syntax: .re2SafeRegex,
            action: .exclude,
            pattern: "((()){1000}){1000}"
        )
        guard case .failure(let error) = engine.validate(rule) else {
            return XCTFail("Expected validation failure")
        }
        XCTAssertEqual(error, .unsafeRegex("compiled expression exceeds 16384 expansion steps"))
    }

    func testRegexSupportsRE2ASCIIClassesBoundariesHexAndLazySuffix() throws {
        let classRule = SelectionRule(
            syntax: .re2SafeRegex,
            action: .exclude,
            pattern: #"^\x{8D44}\x{6599}/[^/\s]+?-[\d\w]{2,4}$"#
        )
        XCTAssertEqual(
            try engine.evaluate(path: "资料/猫-a7_", isDirectory: false, rules: [classRule]).action,
            .exclude
        )
        XCTAssertEqual(
            try engine.evaluate(path: "资料/猫 狗-a7", isDirectory: false, rules: [classRule]).action,
            .include
        )

        let boundaryRule = SelectionRule(
            syntax: .re2SafeRegex,
            action: .exclude,
            pattern: #"\btemp\B"#
        )
        XCTAssertEqual(
            try engine.evaluate(path: "temporary.txt", isDirectory: false, rules: [boundaryRule]).action,
            .exclude
        )
        XCTAssertEqual(
            try engine.evaluate(path: "temp.txt", isDirectory: false, rules: [boundaryRule]).action,
            .include
        )
    }

    func testUnsupportedRE2FeaturesFailClosedWithStableErrors() {
        let cases: [(String, RuleValidationError)] = [
            (#"(?:notes)"#, .unsupportedRegexFeature("group extension")),
            (#"[[:alpha:]]"#, .unsupportedRegexFeature("nested or POSIX character class")),
            (#"\p{Greek}"#, .unsupportedRegexFeature("Unicode character class")),
            (#"\012"#, .unsupportedRegexFeature("octal escape")),
            (#"a{1001}"#, .unsupportedRegexFeature("counted repetition above 1000")),
        ]
        for (pattern, expected) in cases {
            let rule = SelectionRule(syntax: .re2SafeRegex, action: .exclude, pattern: pattern)
            guard case .failure(let error) = engine.validate(rule) else {
                XCTFail("Expected validation failure for \(pattern)")
                continue
            }
            XCTAssertEqual(error, expected, pattern)
        }
    }

    func testPreviewOnlyCountsSafeEvictionBytes() throws {
        let rule = SelectionRule(syntax: .syncthingGlob, action: .exclude, pattern: "**")
        let items = [
            item(id: "safe", size: 10, dirty: false, replicas: 1),
            item(id: "dirty", size: 20, dirty: true, replicas: 1),
            item(id: "unique", size: 30, dirty: false, replicas: 0),
        ]
        let preview = try engine.preview(items: items, rules: [rule])
        XCTAssertEqual(preview.excludedFiles, 3)
        XCTAssertEqual(preview.releasableBytes, 10)
    }

    private func item(id: String, size: Int64, dirty: Bool, replicas: Int) -> IndexedItem {
        IndexedItem(
            id: id,
            folderID: folder,
            relativePath: "\(id).txt",
            isDirectory: false,
            size: size,
            modifiedAt: .now,
            contentVersion: Data(id.utf8),
            metadataVersion: Data(id.utf8),
            availability: .local,
            hasUnuploadedChanges: dirty,
            remoteReplicaCount: replicas
        )
    }
}
