import XCTest

/// Every `ORA-*` identifier cited in the source must actually exist in `SPEC.md`.
///
/// This guards a failure mode that had already done real damage: a citation reads as "the spec
/// requires this," which shuts down the question of whether the code should exist at all. 17 of the
/// identifiers in `Sources/` and `Tests/` turned out to be invented in comments, and one — ORA-CAP-005
/// — had been reused for a second, unrelated requirement. The microphone control grew a third state
/// that way, its supporting machinery citing two IDs that were never in the spec, while the real
/// ORA-CAP-002 had sanctioned exactly two states the whole time.
///
/// The check is one-directional on purpose: a spec requirement with no citation is fine (plenty are
/// satisfied without a comment saying so). A citation with no requirement is not.
final class SpecCitationTests: XCTestCase {

    /// Matches `ORA-CAP-004` and the compound form `ORA-CAP-004/013`, which spells the second ID
    /// without repeating the prefix — the form that hid ORA-CAP-013 from the first audit entirely.
    private static let pattern = try! NSRegularExpression(pattern: #"ORA-([A-Z]+)-(\d+)((?:/\d+)*)"#)

    private func identifiers(in text: String) -> Set<String> {
        var found: Set<String> = []
        let range = NSRange(text.startIndex..., in: text)
        for match in Self.pattern.matches(in: text, range: range) {
            guard let prefixRange = Range(match.range(at: 1), in: text),
                  let firstRange = Range(match.range(at: 2), in: text) else { continue }
            let prefix = String(text[prefixRange])
            found.insert("ORA-\(prefix)-\(text[firstRange])")
            if let tailRange = Range(match.range(at: 3), in: text) {
                for part in text[tailRange].split(separator: "/") {
                    found.insert("ORA-\(prefix)-\(part)")
                }
            }
        }
        return found
    }

    private var repoRoot: URL {
        // …/Tests/OratorKitTests/SpecCitationTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func swiftFiles(under directory: String) -> [URL] {
        let base = repoRoot.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    func testEveryCitedRequirementExistsInTheSpec() throws {
        let spec = try String(contentsOf: repoRoot.appendingPathComponent("SPEC.md"), encoding: .utf8)
        let defined = identifiers(in: spec)
        XCTAssertFalse(defined.isEmpty, "SPEC.md parsed to zero requirement ids — the path or regex is wrong")

        var orphans: [String: Set<String>] = [:]   // id -> files citing it
        for file in swiftFiles(under: "Sources") + swiftFiles(under: "Tests") {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for id in identifiers(in: text) where !defined.contains(id) {
                orphans[id, default: []].insert(file.lastPathComponent)
            }
        }

        XCTAssertTrue(orphans.isEmpty, """
            These ORA-* identifiers are cited in code but do not exist in SPEC.md:
            \(orphans.sorted(by: { $0.key < $1.key })
                .map { "  \($0.key) — cited in \($0.value.sorted().joined(separator: ", "))" }
                .joined(separator: "\n"))
            Either add the requirement to SPEC.md, or drop the identifier and keep the prose rationale.
            """)
    }

    /// A requirement id must be defined exactly once. ORA-CAP-005 was previously used for both
    /// "protect the leading phoneme" (in the spec) and "a substituted selection reads as Automatic"
    /// (in four code sites) — two unrelated rules that a reader could not tell apart.
    func testNoRequirementIdIsDefinedTwice() throws {
        let spec = try String(contentsOf: repoRoot.appendingPathComponent("SPEC.md"), encoding: .utf8)
        var counts: [String: Int] = [:]
        for line in spec.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ORA-") else { continue }   // a definition, not a cross-reference
            for id in identifiers(in: String(trimmed.prefix(24))) { counts[id, default: 0] += 1 }
        }
        let duplicates = counts.filter { $0.value > 1 }.keys.sorted()
        XCTAssertTrue(duplicates.isEmpty, "defined more than once in SPEC.md: \(duplicates)")
    }
}
