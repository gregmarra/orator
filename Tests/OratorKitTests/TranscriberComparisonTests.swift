import XCTest
@preconcurrency import AVFoundation
import Speech
@testable import OratorKit

/// Measures the trade Orator declined: `SpeechTranscriber` (no biasing possible) against
/// `DictationTranscriber` (the only module that honours `contextualStrings`).
///
/// **Why this exists.** Orator pins `SpeechTranscriber` on the belief that it is the more accurate
/// module and that vocabulary biasing is not worth swapping away from it. That belief was inherited
/// from documentation and third-party benchmarks — Apple has never published a comparison between
/// these two modules, and neither has anyone else. This harness produces the number first-hand.
///
/// It builds analyzers directly rather than going through `SpeechEngine`, because the production
/// engine no longer has a `DictationTranscriber` path at all.
///
/// Three arms over identical audio:
///   A. SpeechTranscriber                          — today's shipping behaviour
///   B. DictationTranscriber, no context           — isolates the MODEL cost of the swap
///   C. DictationTranscriber + contextualStrings   — isolates the BIASING benefit
/// Plus a control: SpeechTranscriber *with* contextualStrings set, which should be byte-identical
/// to arm A if the silent-no-op claim is true.
///
/// A→B is the price. B→C is the prize. The feature is only worth having if the prize is bigger.
///
/// Opt-in: synthesizes speech and takes minutes.
///     ORATOR_ACCURACY=1 swift test --filter TranscriberComparisonTests
final class TranscriberComparisonTests: XCTestCase {

    /// Ordinary prose — scored on WER, and the only thing that measures the model gap. Deliberately
    /// contains no terms from the bias list, because that is the case biasing is known to HURT.
    private static let plainPhrases = [
        "the quick brown fox jumps over the lazy dog",
        "please schedule the meeting for four thirty on Tuesday the twenty third",
        "the invoice total came to nine hundred and forty two dollars",
        "their there and they're are homophones that trip up dictation",
        "remind me to buy milk eggs bread and coffee on the way home",
        "she sells seashells by the seashore on a sunny afternoon",
    ]

    /// Jargon-bearing sentences — scored on whether the TERM survives, not on WER. These are the
    /// utterances a vocabulary feature exists to fix.
    private static let termPhrases: [(phrase: String, term: String)] = [
        ("I pushed the fix to Claude Code this morning", "Claude Code"),
        ("the audio comes in through the Yeti X microphone", "Yeti X"),
        ("we should refactor the session coordinator in OratorKit", "OratorKit"),
        ("the transcript comes back from SpeechAnalyzer", "SpeechAnalyzer"),
        ("check whether DictationTranscriber honours the hints", "DictationTranscriber"),
    ]

    private static var biasTerms: [String] { termPhrases.map(\.term) }

    // MARK: Arms

    private enum Arm: String, CaseIterable {
        case speechTranscriber          = "A. SpeechTranscriber"
        case dictationPlain             = "B. DictationTranscriber"
        case dictationBiased            = "C. DictationTranscriber + bias"
        case speechTranscriberBiased    = "control: SpeechTranscriber + bias"

        var usesDictation: Bool { self == .dictationPlain || self == .dictationBiased }
        var setsContext: Bool { self == .dictationBiased || self == .speechTranscriberBiased }
    }

    /// Run one utterance through one arm and return the confirmed transcript.
    ///
    /// Builds a fresh analyzer per utterance for the same reason `SpeechEngine` does: reusing one
    /// across sessions corrupts it.
    @MainActor
    private func transcribe(_ url: URL, arm: Arm, vocabulary: [String]) async throws -> String {
        let speech = SpeechTranscriber(locale: Locale(identifier: "en-US"),
                                       transcriptionOptions: [],
                                       reportingOptions: [.volatileResults],
                                       attributeOptions: [])
        let dictation = DictationTranscriber(locale: Locale(identifier: "en-US"),
                                             contentHints: [],
                                             transcriptionOptions: [],
                                             reportingOptions: [.volatileResults],
                                             attributeOptions: [])
        let module: any SpeechModule = arm.usesDictation ? dictation : speech
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        else { XCTFail("no audio format for \(arm.rawValue)"); return "" }

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let analyzer = SpeechAnalyzer(
            modules: [module],
            options: SpeechAnalyzer.Options(priority: .high, modelRetention: .processLifetime))
        try await analyzer.prepareToAnalyze(in: format)

        if arm.setsContext {
            let context = AnalysisContext()
            context.contextualStrings = [.general: vocabulary]
            try await analyzer.setContext(context)
        }
        try await analyzer.start(inputSequence: stream)

        // Collect confirmed text off the module's own results sequence.
        let collected = Collected()
        let results: Task<Void, Never>
        if arm.usesDictation {
            results = Task {
                do { for try await r in dictation.results where r.isFinal {
                    collected.append(String(r.text.characters)) } } catch {}
            }
        } else {
            results = Task {
                do { for try await r in speech.results where r.isFinal {
                    collected.append(String(r.text.characters)) } } catch {}
            }
        }

        // Feed at wall-clock rate — fed flat out the analyzer returns nothing.
        let capture = FileAudioCapture(url: url, realtime: true)
        let input = try capture.start(outputFormat: format)
        for await buffer in input { cont.yield(buffer) }
        cont.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        try? await Task.sleep(for: .milliseconds(300))
        results.cancel()
        return collected.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Whether the term survived recognition, compared the way a user would judge it: case- and
    /// punctuation-insensitive, but the WORDS have to be right.
    private static func containsTerm(_ term: String, in transcript: String) -> Bool {
        func norm(_ s: String) -> String {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        return norm(transcript).contains(norm(term))
    }

    // MARK: The run

    @MainActor
    func testCompareTranscribers() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ORATOR_ACCURACY"] != nil,
                          "set ORATOR_ACCURACY=1 to run the transcriber comparison (takes minutes)")
        let engine = SpeechEngine(locale: Locale(identifier: "en-US"))
        let installed = await engine.modelStatus() == .installed
        try XCTSkipUnless(installed, "en-US model not installed")

        // Synthesize once; every arm sees identical audio so differences are the module's.
        var plain: [(String, URL)] = []
        for (i, p) in Self.plainPhrases.enumerated() {
            plain.append((p, try sayToFile(p, "cmp-plain-\(i).aiff")))
        }
        var termed: [(phrase: String, term: String, url: URL)] = []
        for (i, t) in Self.termPhrases.enumerated() {
            termed.append((t.phrase, t.term, try sayToFile(t.phrase, "cmp-term-\(i).aiff")))
        }

        var werByArm: [Arm: Double] = [:]
        var recallByArm: [Arm: Int] = [:]
        var plainTranscripts: [Arm: [String]] = [:]

        for arm in Arm.allCases {
            var werTotal = 0.0
            var texts: [String] = []
            for (reference, url) in plain {
                let text = try await transcribe(url, arm: arm, vocabulary: Self.biasTerms)
                texts.append(text)
                werTotal += AccuracyHarnessTests.wordErrorRate(reference: reference, hypothesis: text)
            }
            werByArm[arm] = werTotal / Double(plain.count)
            plainTranscripts[arm] = texts

            var hits = 0
            for item in termed {
                let text = try await transcribe(item.url, arm: arm, vocabulary: Self.biasTerms)
                let hit = Self.containsTerm(item.term, in: text)
                if hit { hits += 1 } else { print("   [\(arm.rawValue)] missed '\(item.term)': \(text)") }
            }
            recallByArm[arm] = hits
            print(">>> \(arm.rawValue): plain WER \(String(format: "%.4f", werByArm[arm]!)), "
                  + "term recall \(hits)/\(termed.count)")
        }

        print("\n=== RESULT ===")
        let a = werByArm[.speechTranscriber]!, b = werByArm[.dictationPlain]!
        print(String(format: "A→B  model cost of the swap: WER %.4f → %.4f", a, b))
        print("B→C  biasing gain: term recall \(recallByArm[.dictationPlain]!)"
              + " → \(recallByArm[.dictationBiased]!) of \(termed.count)")
        print("A    SpeechTranscriber term recall: \(recallByArm[.speechTranscriber]!)/\(termed.count)")

        // The silent no-op claim, tested rather than cited: setting contextualStrings on a
        // SpeechTranscriber session must change nothing.
        XCTAssertEqual(plainTranscripts[.speechTranscriber], plainTranscripts[.speechTranscriberBiased],
                       "contextualStrings appears to AFFECT SpeechTranscriber — if this fails, the "
                       + "premise for deleting the vocabulary feature is wrong")
    }
}

/// Accumulates confirmed text across a results task. A reference box because the task is `@Sendable`.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [String] = []
    func append(_ s: String) { lock.lock(); parts.append(s); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return parts.joined() }
}
