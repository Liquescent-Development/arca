import XCTest

@testable import ArcaEngine

/// Direct tests for the tokenizer both source-text guards now depend on.
///
/// The guards in `CreatePathSeamTests` and `ContainerBridgePathsTests` assert a count of one
/// over a whole 4700-line file. That count staying at one is very weak evidence that the
/// tokenizer is correct: almost any bug in it leaves those two particular counts alone, and a
/// guard whose instrument is untested is the same silent pass the guards themselves exist to
/// prevent. Three earlier attempts at that seam each looked closed and were not.
///
/// So each case below is a shape someone could use to defeat a guard, or a shape that would
/// make one fire when it should not. `sweep()` stands in for the guarded token.
final class SwiftSourceTests: XCTestCase {

    private let token = "sweep()"

    // MARK: - Comments cannot supply a token

    func testALineCommentContributesNothing() {
        let source = "let value = 1  // sweep()"
        XCTAssertFalse(SwiftSource.codeOnly(source).contains(token))
        XCTAssertTrue(SwiftSource.codeOnly(source).contains("let value = 1"))
    }

    func testABlockCommentContributesNothingAndMayNest() {
        let source = "/* outer /* sweep() */ still inside */ let value = 1"
        XCTAssertFalse(SwiftSource.codeOnly(source).contains(token))
        XCTAssertTrue(SwiftSource.codeOnly(source).contains("let value = 1"))
    }

    func testACommentDoesNotJoinTheLinesAroundIt() {
        let source = "let a = sw  /* comment\nspanning lines */  eep()"
        XCTAssertFalse(SwiftSource.codeOnly(source).contains(token))
    }

    // MARK: - String literals cannot supply a token, in any of their four forms

    func testAPlainLiteralContributesNothing() {
        let source = #"logger.info("sweep() moved to the unpack path")"#
        XCTAssertFalse(SwiftSource.codeOnly(source).contains(token))
    }

    func testARawLiteralContributesNothing() {
        let source = ##"let note = #"sweep()"#"##
        XCTAssertFalse(SwiftSource.codeOnly(source).contains(token))
    }

    func testAMultilineLiteralContributesNothingAndKeepsItsLines() {
        let source = ##"""
            let note = """
                sweep()
                """
            let after = marker()
            """##
        let code = SwiftSource.codeOnly(source)
        XCTAssertFalse(code.contains(token))
        XCTAssertTrue(code.contains("marker()"), "code after a multiline literal must survive")
    }

    func testAnEscapedQuoteDoesNotEndALiteralEarly() {
        let source = #"let note = "a \"sweep()\" b""#
        XCTAssertFalse(SwiftSource.codeOnly(source).contains(token))
    }

    // MARK: - A literal must not swallow the code around it

    /// The measured regression that a comment-only stripper had: the `//` inside `"oci://"`
    /// was read as the start of a comment, so the call after it vanished and a real second
    /// sweep on the unpack path went uncounted.
    func testASlashSlashInsideALiteralDoesNotStartAComment() {
        let source = #"if reference.hasPrefix("oci://") { try unpacker.sweep() }"#
        XCTAssertTrue(
            SwiftSource.codeOnly(source).contains(token),
            "a call after a literal containing // must still be counted"
        )
    }

    func testABlockCommentOpenerInsideALiteralDoesNotStartAComment() {
        let source = #"if pattern == "/*" { try unpacker.sweep() }"#
        XCTAssertTrue(SwiftSource.codeOnly(source).contains(token))
    }

    func testAQuoteInsideACommentDoesNotStartALiteral() {
        let source = "// he said \"hello\nlet value = sweep()"
        XCTAssertTrue(SwiftSource.codeOnly(source).contains(token))
    }

    // MARK: - Interpolation carries real code, and is kept

    func testInterpolatedCodeIsKept() {
        let source = #"logger.info("done \(try unpacker.sweep()) ok")"#
        XCTAssertTrue(
            SwiftSource.codeOnly(source).contains(token),
            "a call inside interpolation really runs and must be counted"
        )
    }

    func testALiteralNestedInsideInterpolationIsStillStripped() {
        let source = #"logger.info("\(describe("sweep()")) done")"#
        let code = SwiftSource.codeOnly(source)
        XCTAssertTrue(code.contains("describe("), "the interpolated call must survive")
        XCTAssertFalse(code.contains(token), "the literal inside it must not")
    }

    func testABackslashParenInARawLiteralIsNotInterpolation() {
        let source = ##"let note = #"\(sweep())"#"##
        XCTAssertFalse(
            SwiftSource.codeOnly(source).contains(token),
            ##"in a raw literal \( is ordinary text; only \#( interpolates"##
        )
    }

    // MARK: - The flattened view keeps literal text without letting it pose as code

    func testFlattenedLiteralsKeepTheirText() {
        let source = #"store.appendingPathComponent("containers")"#
        XCTAssertTrue(
            SwiftSource.codeWithFlattenedLiterals(source)
                .contains(#".appendingPathComponent("containers")"#)
        )
    }

    func testARawLiteralCannotPoseAsCodePlusALiteral() {
        let source = ###"let note = #".appendingPathComponent("containers")"#"###
        XCTAssertFalse(
            SwiftSource.codeWithFlattenedLiterals(source)
                .contains(#".appendingPathComponent("containers")"#),
            "the raw literal's interior quotes must be dropped, or it matches a quoted token"
        )
    }

    func testFlattenedLiteralsStillDropComments() {
        let source = #"// store.appendingPathComponent("containers")"#
        XCTAssertFalse(
            SwiftSource.codeWithFlattenedLiterals(source)
                .contains(#".appendingPathComponent("containers")"#)
        )
    }
}
