//
// HangulComposerTests.swift — Acceptance tests for the two-set (두벌식) Hangul composer.
//
// These tests drive the composer through realistic iOS Korean keyboard sequences and
// verify both the final preedit state and the full diff stream (backspace count +
// emitted text per step). The diff stream is what the PTY integration layer consumes,
// so it's the canonical observable behavior.
//

import XCTest
@testable import HangulSwift

final class HangulComposerTests: XCTestCase {
    /// Drive a sequence of jamo through the composer and return the (preedit, fullDiffLog).
    /// `fullDiffLog` is one entry per input: `(backspaces, text)`.
    private func drive(_ inputs: String) -> (preedit: String, log: [(Int, String)]) {
        let composer = HangulComposer()
        var log: [(Int, String)] = []
        for ch in inputs {
            let diff = composer.input(ch)
            log.append((diff.backspaces, diff.text))
        }
        return (composer.preedit, log)
    }

    // MARK: - HANDOFF §3.2 acceptance examples (libhangul-equivalent behavior)

    func testBareInitial() {
        let (preedit, log) = drive("ㄱ")
        XCTAssertEqual(preedit, "ㄱ")
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log[0].0, 0)
        XCTAssertEqual(log[0].1, "ㄱ")
    }

    func test_가() {
        let (preedit, log) = drive("ㄱㅏ")
        XCTAssertEqual(preedit, "가")
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(log[0].1, "ㄱ")    // step 1: bare initial
        XCTAssertEqual(log[1].0, 1)        // step 2: erase the "ㄱ"
        XCTAssertEqual(log[1].1, "가")    // step 2: emit the syllable
    }

    func test_간() {
        let (preedit, _) = drive("ㄱㅏㄴ")
        XCTAssertEqual(preedit, "간")
    }

    /// Final promotion: 간 + ㄴ → 간 (committed) + ㄴ (new initial).
    /// The final ㄴ from 간 stays on the previous syllable; the new ㄴ starts a fresh one.
    /// Wait — actually in 두벌식 this is a simple final (not composite), so the new ㄴ
    /// can be combined with the existing ㄴ as a *final*: ㄴ+ㅎ → ㄶ, but ㄴ+ㄴ has no
    /// combination, so the result is final promotion: 간 commits, ㄴ becomes next initial.
    func test_간Plus_ㄴ_finalPromotion() {
        let composer = HangulComposer()
        _ = composer.input("ㄱ")
        _ = composer.input("ㅏ")
        _ = composer.input("ㄴ")
        XCTAssertEqual(composer.preedit, "간")

        // Drive an explicit fourth input and inspect.
        let diff = composer.input("ㄴ")
        // No combination available → commit "간", new preedit is "ㄴ".
        XCTAssertEqual(diff.text, "간ㄴ")
        // Erase the previous preedit ("간" = 1 char).
        XCTAssertEqual(diff.backspaces, 1)
        XCTAssertEqual(composer.preedit, "ㄴ")
    }

    /// Composite final: ㄱ + ㅓ + ㅄ → 겂 (final = ㅄ, the ㅂ+ㅅ combination).
    func testCompositeFinal_겂() {
        let composer = HangulComposer()
        _ = composer.input("ㄱ")
        _ = composer.input("ㅓ")
        XCTAssertEqual(composer.preedit, "거")
        _ = composer.input("ㅂ")
        XCTAssertEqual(composer.preedit, "겁")
        _ = composer.input("ㅅ")
        // ㅂ + ㅅ combine into ㅄ as the final → preedit becomes 겂.
        XCTAssertEqual(composer.preedit, "겂")
    }

    /// Composite medial: ㄱ + ㅗ + ㅏ → 과 (medial = ㅘ, the ㅗ+ㅏ combination).
    func testCompositeMedial_과() {
        let composer = HangulComposer()
        _ = composer.input("ㄱ")
        _ = composer.input("ㅗ")
        XCTAssertEqual(composer.preedit, "고")
        _ = composer.input("ㅏ")
        // ㅗ + ㅏ combine into ㅘ → preedit becomes 과.
        XCTAssertEqual(composer.preedit, "과")
    }

    /// "안녕" full sequence: ㅇㅏㄴ + ㄴㅕㅇ.
    /// At step 4 (the 2nd ㄴ), 안 commits and ㄴ becomes the new initial.
    func test_안녕() {
        let composer = HangulComposer()
        var emitted = ""
        for ch in "ㅇㅏㄴㄴㅕㅇ" {
            let diff = composer.input(ch)
            // Apply diff to a running buffer.
            if diff.backspaces > 0 {
                emitted = String(emitted.dropLast(diff.backspaces))
            }
            emitted.append(diff.text)
        }
        XCTAssertEqual(composer.preedit, "녕")
        // The committed prefix should be "안".
        XCTAssertTrue(emitted.hasPrefix("안"), "expected emitted to start with 안, got \(emitted)")
        // The full visible buffer (committed + preedit) should be "안녕".
        XCTAssertEqual(emitted, "안녕")
    }

    /// "안녕하세요" — the canonical sentence from HANDOFF §6.2 dogfood checklist.
    func test_안녕하세요() {
        let composer = HangulComposer()
        var emitted = ""
        for ch in "ㅇㅏㄴㄴㅕㅇㅎㅏㅅㅔㅇㅛ" {
            let diff = composer.input(ch)
            if diff.backspaces > 0 {
                emitted = String(emitted.dropLast(diff.backspaces))
            }
            emitted.append(diff.text)
        }
        // Final flush so the last syllable seals.
        let final = composer.flush()
        if final.backspaces > 0 {
            emitted = String(emitted.dropLast(final.backspaces))
        }
        emitted.append(final.text)
        XCTAssertEqual(emitted, "안녕하세요")
    }

    // MARK: - Backspace

    /// Backspace at IMF state: 간 → 가.
    func testBackspace_간_to_가() {
        let composer = HangulComposer()
        _ = composer.input("ㄱ")
        _ = composer.input("ㅏ")
        _ = composer.input("ㄴ")
        XCTAssertEqual(composer.preedit, "간")
        let diff = composer.backspace()
        XCTAssertEqual(composer.preedit, "가")
        XCTAssertEqual(diff.backspaces, 1)
        XCTAssertEqual(diff.text, "가")
    }

    /// Backspace at IM state: 가 → ㄱ.
    func testBackspace_가_to_ㄱ() {
        let composer = HangulComposer()
        _ = composer.input("ㄱ")
        _ = composer.input("ㅏ")
        let diff = composer.backspace()
        XCTAssertEqual(composer.preedit, "ㄱ")
        XCTAssertEqual(diff.text, "ㄱ")
        XCTAssertEqual(diff.backspaces, 1)
    }

    /// Backspace at I state: ㄱ → empty.
    func testBackspace_ㄱ_to_empty() {
        let composer = HangulComposer()
        _ = composer.input("ㄱ")
        let diff = composer.backspace()
        XCTAssertEqual(composer.preedit, "")
        XCTAssertEqual(diff.text, "")
        XCTAssertEqual(diff.backspaces, 1)
    }

    /// Backspace on empty composer → pass through as host BS.
    func testBackspace_emptyPassthrough() {
        let composer = HangulComposer()
        let diff = composer.backspace()
        XCTAssertEqual(diff.backspaces, 1)
        XCTAssertEqual(diff.text, "")
    }

    /// Backspace on composite final: 겂 → 겁.
    func testBackspace_compositeFinal() {
        let composer = HangulComposer()
        _ = composer.input("ㄱ")
        _ = composer.input("ㅓ")
        _ = composer.input("ㅂ")
        _ = composer.input("ㅅ")
        XCTAssertEqual(composer.preedit, "겂")
        let diff = composer.backspace()
        XCTAssertEqual(composer.preedit, "겁")
        XCTAssertEqual(diff.text, "겁")
    }

    /// Backspace on composite medial: 과 → 고.
    func testBackspace_compositeMedial() {
        let composer = HangulComposer()
        _ = composer.input("ㄱ")
        _ = composer.input("ㅗ")
        _ = composer.input("ㅏ")
        XCTAssertEqual(composer.preedit, "과")
        let diff = composer.backspace()
        XCTAssertEqual(composer.preedit, "고")
        XCTAssertEqual(diff.text, "고")
    }

    // MARK: - Flush

    func testFlush_committedAndCleared() {
        let composer = HangulComposer()
        _ = composer.input("ㄱ")
        _ = composer.input("ㅏ")
        XCTAssertTrue(composer.isComposing)
        let diff = composer.flush()
        XCTAssertFalse(composer.isComposing)
        XCTAssertEqual(diff.text, "가")
        XCTAssertEqual(diff.backspaces, 1)
    }

    func testFlush_emptyIsNoOp() {
        let composer = HangulComposer()
        let diff = composer.flush()
        XCTAssertEqual(diff, .none)
    }

    // MARK: - Reset

    func testReset_dropsStateWithoutEmitting() {
        let composer = HangulComposer()
        _ = composer.input("ㄱ")
        _ = composer.input("ㅏ")
        composer.reset()
        XCTAssertFalse(composer.isComposing)
        XCTAssertEqual(composer.preedit, "")
    }

    // MARK: - Non-jamo passthrough

    func testNonJamoPassthrough_commitsAndForwards() {
        let composer = HangulComposer()
        _ = composer.input("ㄱ")
        _ = composer.input("ㅏ")
        XCTAssertEqual(composer.preedit, "가")
        // ASCII 'a' arrives mid-composition → commit "가" + pass 'a' through.
        let diff = composer.input("a")
        XCTAssertEqual(diff.text, "가a")
        XCTAssertEqual(diff.backspaces, 1)
        XCTAssertFalse(composer.isComposing)
    }

    // MARK: - Static helper

    func testIsHangulJamo() {
        XCTAssertTrue(HangulComposer.isHangulJamo("ㄱ".unicodeScalars.first!))
        XCTAssertTrue(HangulComposer.isHangulJamo("ㅣ".unicodeScalars.first!))
        XCTAssertFalse(HangulComposer.isHangulJamo("a".unicodeScalars.first!))
        XCTAssertFalse(HangulComposer.isHangulJamo("가".unicodeScalars.first!)) // precomposed syllable
    }
}
