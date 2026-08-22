import ContainerBridge
import Foundation
import Logging
@testable import ArcaEngine

/// The ContainerBridge sources this target's source-text guards read.
///
/// Shared rather than copied into each guard's own file. Two spellings of "find the repo
/// root from `#filePath`" would be free to drift, and the way that drifts is that one
/// guard silently starts reading a file that is not the one it names -- which for a text
/// guard is indistinguishable from the guard passing.
///
/// Located from `#filePath` rather than from the test bundle, because the bundle holds no
/// sources. A missing or unreadable file throws and fails the test; it is never skipped. A
/// guard that quietly passes when it cannot find what it guards is worse than no guard.
enum BridgeSources {
    static func containerManager(testFile: StaticString = #filePath) throws -> String {
        try read("Sources/ContainerBridge/ContainerManager.swift", testFile: testFile)
    }

    private static func read(_ relativePath: String, testFile: StaticString) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(testFile)")
            .deletingLastPathComponent()  // ArcaEngineTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8
        )
    }
}
/// A Swift source file reduced to the parts a source-text guard may honestly count.
///
/// **Why this exists.** Both source-text guards in this target count occurrences of a token in
/// `ContainerManager.swift` and assert the count is exactly one. Over raw text that is unsound
/// in the direction that does not announce itself: a comment or a string literal can *supply*
/// the occurrence, so an edit that removes the real code and leaves prose behind passes. Three
/// successive attempts at `CreatePathSeamTests`'s guard each closed one shape of this and left
/// another -- first a bare spelling in a comment, then a receiver-qualified spelling in a
/// comment, then a string literal. The shapes are unbounded. The fix is to stop counting text
/// that is not code.
///
/// **Two views, because the two guards need opposite things.** `CreatePathSeamTests` counts a
/// bare call, so literal text is noise to it and must go. `ContainerBridgePathsTests` counts
/// `.appendingPathComponent("containers")`, whose entire discriminating power is the literal
/// `"containers"` -- delete literal text and that guard stops telling the containers directory
/// from any other. One tokenizer, two emissions, rather than one view that serves neither.
///
/// **A tokenizer, not a parser.** It knows comments, all four string-literal forms (single and
/// multiline, each in a plain and a raw variant) and interpolation. It does not know
/// declarations, so it cannot tell a call from an argument label or from dead code, and
/// neither guard claims otherwise. It does not know regex literals; `ContainerManager.swift`
/// contains none. An unterminated comment or literal would swallow the remainder of the file,
/// which cannot happen here because the file it reads is compiled by this same target and
/// would fail the build first.
enum SwiftSource {

    /// `source` with comments removed and string-literal text removed.
    ///
    /// A literal collapses to an empty `""` pair, so the code around it is undisturbed. Use
    /// this wherever a literal that spelt the searched-for token would be a false PASS.
    static func codeOnly(_ source: String) -> String {
        var index = 0
        return scanCode(
            Array(source), from: &index,
            keepingLiteralText: false, stoppingAtCloseParenthesis: false
        )
    }

    /// `source` with comments removed and string-literal text kept, flattened.
    ///
    /// Each literal is re-emitted as one plain `"..."` around its text, with raw-string hashes
    /// and escape sequences normalised away and any quote character *inside* the text dropped.
    ///
    /// The flattening is load-bearing, not tidiness. Without it a raw string such as
    /// `#".appendingPathComponent("containers")"#` would re-emit its own interior quotes and
    /// satisfy a token that is spelt with quotes -- the same false PASS in a new costume.
    /// Flattened it emits `".appendingPathComponent(containers)"`, which matches nothing.
    static func codeWithFlattenedLiterals(_ source: String) -> String {
        var index = 0
        return scanCode(
            Array(source), from: &index,
            keepingLiteralText: true, stoppingAtCloseParenthesis: false
        )
    }

    /// Scans forward emitting code, recursing into interpolation.
    ///
    /// `stoppingAtCloseParenthesis` is how an interpolation's extent is found: the recursive
    /// call returns at the first `)` that its own `(` did not open, leaving `index` on it.
    /// **Interpolated code is kept**, deliberately. `\(unpacker.reapOrphanedStagingFiles())`
    /// is a call that really runs, so a guard that dropped it would report zero calls for a
    /// file that makes one -- a false RED, and worse, it would let the call be moved into an
    /// interpolation to escape the count. Text nested one level deeper, inside a literal
    /// inside the interpolation, is stripped by the recursion just as it is at the top level.
    private static func scanCode(
        _ characters: [Character],
        from index: inout Int,
        keepingLiteralText keepLiteralText: Bool,
        stoppingAtCloseParenthesis stopAtCloseParenthesis: Bool
    ) -> String {
        var code = String()
        var parenthesisDepth = 0

        while index < characters.count {
            if matches(characters, at: index, "//") {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }

            if matches(characters, at: index, "/*") {
                code += skipBlockComment(characters, from: &index)
                continue
            }

            let hashes = hashRun(characters, at: index)
            if character(characters, at: index + hashes) == "\"" {
                code += "\""
                code += scanStringLiteral(
                    characters, from: &index,
                    hashes: hashes, keepingLiteralText: keepLiteralText
                )
                code += "\""
                continue
            }

            let current = characters[index]
            if stopAtCloseParenthesis {
                if current == "(" {
                    parenthesisDepth += 1
                } else if current == ")" {
                    if parenthesisDepth == 0 { return code }
                    parenthesisDepth -= 1
                }
            }

            code.append(current)
            index += 1
        }

        return code
    }

    /// Consumes a `/* */` comment, tracking the nesting Swift permits, and returns only the
    /// newlines it spanned so that nothing on separate lines is joined into a match.
    private static func skipBlockComment(
        _ characters: [Character], from index: inout Int
    ) -> String {
        var newlines = String()
        var depth = 0

        while index < characters.count {
            if matches(characters, at: index, "/*") {
                depth += 1
                index += 2
                continue
            }
            if matches(characters, at: index, "*/") {
                depth -= 1
                index += 2
                if depth == 0 { return newlines }
                continue
            }
            if characters[index] == "\n" { newlines.append("\n") }
            index += 1
        }

        return newlines
    }

    /// Consumes one string literal, opening delimiter onwards, and returns what survives of it.
    ///
    /// `hashes` is the length of the `#` run that opened it, which sets both the closing
    /// delimiter and the escape prefix: in `#"..."#` a lone backslash is an ordinary character
    /// and only `\#` escapes. Escape sequences contribute nothing to the result -- dropping
    /// `\"` is what stops an escaped quote from re-entering the flattened text -- and newlines
    /// are always kept so a multiline literal cannot join the lines around it.
    private static func scanStringLiteral(
        _ characters: [Character],
        from index: inout Int,
        hashes: Int,
        keepingLiteralText keepLiteralText: Bool
    ) -> String {
        index += hashes
        let isMultiline = matches(characters, at: index, "\"\"\"")
        let quote = isMultiline ? "\"\"\"" : "\""
        let quoteLength = isMultiline ? 3 : 1
        index += quoteLength

        var kept = String()

        while index < characters.count {
            if matches(characters, at: index, quote),
                hashRun(characters, at: index + quoteLength) >= hashes
            {
                index += quoteLength + hashes
                return kept
            }

            if characters[index] == "\\", hashRun(characters, at: index + 1) >= hashes {
                let escapeLength = 1 + hashes
                if character(characters, at: index + escapeLength) == "(" {
                    index += escapeLength + 1
                    kept += scanCode(
                        characters, from: &index,
                        keepingLiteralText: keepLiteralText, stoppingAtCloseParenthesis: true
                    )
                    if index < characters.count { index += 1 }
                    continue
                }
                index += escapeLength + 1
                continue
            }

            let current = characters[index]
            if current == "\n" {
                kept.append(current)
            } else if keepLiteralText, current != "\"" {
                kept.append(current)
            }
            index += 1
        }

        return kept
    }

    private static func character(_ characters: [Character], at index: Int) -> Character? {
        index >= 0 && index < characters.count ? characters[index] : nil
    }

    private static func matches(_ characters: [Character], at index: Int, _ text: String) -> Bool {
        let expected = Array(text)
        guard index >= 0, index + expected.count <= characters.count else { return false }
        for offset in 0..<expected.count where characters[index + offset] != expected[offset] {
            return false
        }
        return true
    }

    private static func hashRun(_ characters: [Character], at index: Int) -> Int {
        var length = 0
        while index + length < characters.count, characters[index + length] == "#" { length += 1 }
        return length
    }
}

extension SandboxEngineService {
    /// A service over real ContainerBridge managers against a throwaway state
    /// root. Nothing in Tasks 1-6's tests starts a VM; these managers exist
    /// because the service holds them, not because the tests drive them.
    ///
    /// `StateStore` and `ImageManager` construction is force-tried: a failure
    /// here means the on-disk test fixture (a fresh temp directory) could not
    /// be created, which should fail the test run loudly rather than surface
    /// as an ordinary assertion failure.
    static func forTesting() -> SandboxEngineService {
        forTesting(
            stateRoot: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("arca-engine-tests-\(UUID().uuidString)"),
            // Outside the state root on purpose. Nothing here boots a sandbox,
            // so it is never read, and putting it under the root would quietly
            // restate the derivation `--kernel-path` replaced.
            kernelPath: URL(fileURLWithPath: "/opt/arca/vmlinux")
        )
    }

    /// The same service against a state root and kernel the caller names, so a
    /// test can assert on where the managers were actually rooted.
    ///
    /// The managers come from `EngineManagers` -- the one factory `arca-engine`
    /// itself calls -- and not from a copy of its constructor calls. The copy is
    /// what made this helper a replica of the wiring rather than the wiring:
    /// while it stood, Task 1's review measured that swapping
    /// `imageStoreRoot: paths.imageRootfs` in `ServeCommand` left the whole
    /// suite green. See the measurement recorded on `EngineManagers` for what
    /// the same swap costs now.
    ///
    /// The kernel is a parameter rather than an `EnginePaths` member for the
    /// same reason it is a separate CLI option: it is a read-only input the
    /// engine is handed, not state the engine owns. Deriving it here while
    /// `arca-engine` took it from `--kernel-path` would put the drift back.
    ///
    /// No defaults on either, in keeping with the rule the path parameters on
    /// `ContainerManager` follow: the no-argument overload above states the
    /// throwaway values it wants.
    ///
    /// Nothing here calls `EngineManagers`' managers' `initialize()`. That needs
    /// a live `Containerization.VmnetNetwork`, which is a host resource and not
    /// state-root-scoped; `arca-engine` is the only caller that asks for one.
    static func forTesting(stateRoot: URL, kernelPath: URL) -> SandboxEngineService {
        try! EngineManagers(
            stateRoot: stateRoot,
            kernelPath: kernelPath,
            logLevel: "info",
            logger: Logger(label: "arca-engine-tests")
        ).makeService()
    }
}
