import CoreGraphics
import XCTest

@testable import Hyper

/// The key table is what a hand-edited config is read through and what the recorder
/// writes back, so the two directions have to agree on a single spelling per key code.
final class KeysTests: XCTestCase {
    func testNamesAreCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(Keys.code(for: "c"), 8)
        XCTAssertEqual(Keys.code(for: "  C  "), 8)
        XCTAssertEqual(Keys.code(for: "Space"), 49)
        XCTAssertEqual(Keys.code(for: "F19"), Keys.hyperTrigger)
    }

    func testEscapeAliasResolvesButIsNotCanonical() {
        XCTAssertEqual(Keys.code(for: "esc"), 53)
        XCTAssertEqual(Keys.code(for: "escape"), 53)
        // The alias is accepted on input and never written back out.
        XCTAssertEqual(Keys.name(for: 53), "escape")
    }

    func testRawKeyCodePrefix() {
        XCTAssertEqual(Keys.code(for: "kc:8"), 8)
        XCTAssertEqual(Keys.code(for: "KC:200"), 200)
        XCTAssertNil(Keys.code(for: "kc:"))
        XCTAssertNil(Keys.code(for: "kc:abc"))
        XCTAssertNil(Keys.code(for: "kc:-1"))
    }

    func testUnknownTokenIsRejected() {
        XCTAssertNil(Keys.code(for: "notakey"))
        XCTAssertNil(Keys.code(for: ""))
    }

    func testEveryNamedKeyRoundTrips() {
        for (name, code) in Keys.byName {
            let canonical = Keys.name(for: code)
            XCTAssertEqual(
                Keys.code(for: canonical), code,
                "canonical name '\(canonical)' for \(code) (from '\(name)') does not resolve back"
            )
        }
    }

    func testUnnamedKeyCodeRoundTripsAsRawForm() {
        let unnamed: CGKeyCode = 200
        XCTAssertNil(Keys.byName.values.first { $0 == unnamed })
        XCTAssertEqual(Keys.name(for: unnamed), "kc:200")
        XCTAssertEqual(Keys.code(for: Keys.name(for: unnamed)), unnamed)
    }

    func testCanonicalNameIsStableAcrossLookups() {
        // Built from a dictionary whose iteration order is undefined; the same code must
        // not spell itself differently on two calls.
        for _ in 0..<50 {
            XCTAssertEqual(Keys.name(for: 53), "escape")
        }
    }
}
