//
// HangulComposer.swift — Hangul (한글) jamo → syllable composition state machine.
//
// Independent clean-room implementation of the 두벌식 (Dubeolsik) composition algorithm
// based on the Unicode Standard 16.0 (chapter 18.6 "Hangul Syllables"). No code or data
// was copied from libhangul (LGPL-2.1) or any other licensed library. The algorithm is
// reconstructed from first principles (Unicode L/V/T composition rules and the standard
// 두벌식 keyboard layout).
//

import Foundation

/// Output of a single composer step.
///
/// The composer keeps an internal "preedit" — the in-progress syllable currently visible
/// to the user. Every input step describes how the host (e.g. a PTY terminal) should
/// update its display:
///
///   1. Erase `backspaces` characters from the end of its buffer.
///   2. Append `text`.
///
/// `text` includes any newly *committed* syllables (e.g. when the user starts a fresh
/// syllable, the previous one is sealed and emitted) followed by the new preedit
/// character (if any). This is the same model as the iOS UIKit `setMarkedText:` /
/// `unmarkText` cycle, but lowered into a single diff suitable for character-stream
/// surfaces like a PTY.
public struct HangulDiff: Equatable, Sendable {
    /// Number of *characters* (extended grapheme clusters) to erase from the host's
    /// buffer. In line-editor contexts (zsh, readline, vim insert mode) one BS byte
    /// erases one such cluster. For raw terminals without a line editor, the caller
    /// may need to widen this per column-width.
    public let backspaces: Int

    /// New text to append to the host's buffer. May contain zero or more committed
    /// Hangul syllables (or pass-through scalars) followed by the new preedit.
    public let text: String

    public static let none = HangulDiff(backspaces: 0, text: "")

    public init(backspaces: Int, text: String) {
        self.backspaces = backspaces
        self.text = text
    }
}

/// 두벌식 (2-set) Hangul composer.
///
/// Accepts one Compatibility Jamo (U+3131..U+318E) at a time — the form iOS Korean
/// keyboards emit through `insertText(_:)`. Emits a `HangulDiff` describing how the
/// host should update its display, optionally producing committed syllables when the
/// user moves on to the next syllable.
///
/// Thread-safety: not thread-safe. Confine to a single actor / queue.
public final class HangulComposer {
    // MARK: - State

    /// Current initial (초성, L) index, 0..18, or nil if not yet decided.
    private var initialIndex: Int? = nil

    /// Current medial (중성, V) index, 0..20, or nil.
    private var medialIndex: Int? = nil

    /// Current final (종성, T) index, 1..27, or nil (0 == no final, represented here as nil).
    private var finalIndex: Int? = nil

    /// The last preedit string we asked the host to display. Used to know how many
    /// characters to erase on the next step.
    private var lastPreedit: String = ""

    // MARK: - API

    public init() {}

    /// Whether the composer currently holds an in-progress syllable.
    public var isComposing: Bool { initialIndex != nil || medialIndex != nil || finalIndex != nil }

    /// The current preedit (the character(s) currently visible on the host as
    /// "in-progress"). Always 0 or 1 grapheme cluster.
    public var preedit: String { renderPreedit() }

    /// Process a single jamo scalar. The scalar must be in the Hangul Compatibility
    /// Jamo block (U+3131..U+318E). Non-jamo scalars are committed as-is (the caller
    /// can also short-circuit by checking `HangulComposer.isHangulJamo`).
    public func input(scalar: Unicode.Scalar) -> HangulDiff {
        guard HangulJamoTables.isCompatibilityJamo(scalar) else {
            return flushAndEmit(passthrough: String(scalar))
        }
        if HangulJamoTables.isVowel(scalar) {
            return inputVowel(scalar)
        } else {
            return inputConsonant(scalar)
        }
    }

    /// Convenience overload accepting a `Character`. Only the first scalar is consulted.
    public func input(_ character: Character) -> HangulDiff {
        guard let scalar = character.unicodeScalars.first else { return .none }
        return input(scalar: scalar)
    }

    /// Step the state back by one logical unit:
    ///  - Drop final → medial → initial in that order while composing.
    ///  - Composite finals (e.g. ㄳ) decompose to their left half (ㄱ).
    ///  - Composite medials (e.g. ㅘ) decompose to ㅗ.
    ///  - When empty, returns a passthrough BS so the host can delete one character of
    ///    its own buffer (typical: prior committed syllable).
    public func backspace() -> HangulDiff {
        let priorPreedit = lastPreedit
        if !isComposing {
            // Nothing in our buffer — pass the BS through to the host as a single-char erase.
            return HangulDiff(backspaces: 1, text: "")
        }

        if let finalIdx = finalIndex {
            if let finalScalar = HangulJamoTables.finalIndexToCompatibility[finalIdx],
               let (left, _) = HangulJamoTables.finalDecomposition[finalScalar] {
                // Composite final → keep the left half.
                finalIndex = HangulJamoTables.compatibilityFinalIndex[left]
            } else {
                finalIndex = nil
            }
        } else if let medialIdx = medialIndex {
            if let medialScalar = HangulJamoTables.medialIndexToCompatibility[medialIdx],
               let (left, _) = HangulJamoTables.medialDecomposition[medialScalar] {
                // Composite medial → keep the left half.
                medialIndex = HangulJamoTables.compatibilityMedialIndex[left]
            } else {
                medialIndex = nil
            }
        } else if initialIndex != nil {
            initialIndex = nil
        }

        let newPreedit = renderPreedit()
        let diff = HangulDiff(
            backspaces: graphemeCount(priorPreedit),
            text: newPreedit
        )
        lastPreedit = newPreedit
        return diff
    }

    /// Commit any in-progress syllable to the output and clear the composer.
    /// Returns a diff that erases the current preedit and re-emits it as a "committed"
    /// (sealed) syllable — so the caller can treat the result as final output.
    @discardableResult
    public func flush() -> HangulDiff {
        guard isComposing else { return .none }
        let priorPreedit = lastPreedit
        let committed = renderPreedit()
        initialIndex = nil
        medialIndex = nil
        finalIndex = nil
        lastPreedit = ""
        return HangulDiff(backspaces: graphemeCount(priorPreedit), text: committed)
    }

    /// Discard all composer state without emitting anything. Use when the surface loses
    /// focus or the user explicitly cancels (Esc).
    public func reset() {
        initialIndex = nil
        medialIndex = nil
        finalIndex = nil
        lastPreedit = ""
    }

    // MARK: - Static helpers

    /// True when `scalar` is a Hangul Compatibility Jamo (the form iOS keyboards emit).
    public static func isHangulJamo(_ scalar: Unicode.Scalar) -> Bool {
        HangulJamoTables.isCompatibilityJamo(scalar)
    }

    // MARK: - Vowel input

    private func inputVowel(_ scalar: Unicode.Scalar) -> HangulDiff {
        guard let vIdx = HangulJamoTables.compatibilityMedialIndex[scalar] else {
            return flushAndEmit(passthrough: String(scalar))
        }
        let priorPreedit = lastPreedit

        // Case 1: nothing buffered → just buffer the medial alone. The preedit will be
        // the bare vowel (no initial). This rarely happens with iOS keyboards but we
        // handle it for robustness.
        if initialIndex == nil && medialIndex == nil && finalIndex == nil {
            medialIndex = vIdx
            return emitPreeditDiff(priorPreedit: priorPreedit)
        }

        // Case 2: have an initial but no medial → form an initial+medial syllable.
        if initialIndex != nil && medialIndex == nil && finalIndex == nil {
            medialIndex = vIdx
            return emitPreeditDiff(priorPreedit: priorPreedit)
        }

        // Case 3: have initial+medial (no final) → try medial combination.
        if initialIndex != nil && medialIndex != nil && finalIndex == nil {
            if let currentMedialScalar = HangulJamoTables.medialIndexToCompatibility[medialIndex!],
               let combined = HangulJamoTables.medialCombinations[Pair(currentMedialScalar, scalar)],
               let combinedIdx = HangulJamoTables.compatibilityMedialIndex[combined] {
                medialIndex = combinedIdx
                return emitPreeditDiff(priorPreedit: priorPreedit)
            }
            // No combination possible: commit the current syllable, start a fresh one
            // with this vowel alone (no initial).
            let committed = renderPreedit()
            initialIndex = nil
            medialIndex = vIdx
            finalIndex = nil
            let newPreedit = renderPreedit()
            let diff = HangulDiff(
                backspaces: graphemeCount(priorPreedit),
                text: committed + newPreedit
            )
            lastPreedit = newPreedit
            return diff
        }

        // Case 4: have initial+medial+final → "final promotion". The final moves to
        // become the initial of the new syllable, paired with the incoming vowel.
        if initialIndex != nil && medialIndex != nil && finalIndex != nil {
            return promoteFinalToInitial(withMedial: vIdx, priorPreedit: priorPreedit)
        }

        // Defensive fallback (shouldn't reach): just buffer.
        medialIndex = vIdx
        return emitPreeditDiff(priorPreedit: priorPreedit)
    }

    /// Final-to-initial promotion: when a vowel arrives with IMF state, the final
    /// (possibly composite) splits — the second part becomes the initial of a new
    /// syllable, the first part stays as the final of the previous one.
    private func promoteFinalToInitial(withMedial vIdx: Int, priorPreedit: String) -> HangulDiff {
        // Decompose the final if it's composite.
        let currentFinalScalar = HangulJamoTables.finalIndexToCompatibility[finalIndex!]!
        let movedConsonant: Unicode.Scalar
        if let (kept, moved) = HangulJamoTables.finalDecomposition[currentFinalScalar] {
            // Composite final → reduce previous syllable's final to `kept`, move `moved`.
            finalIndex = HangulJamoTables.compatibilityFinalIndex[kept]
            movedConsonant = moved
        } else {
            // Simple final → previous syllable loses its final entirely; `final` itself
            // moves to the new syllable.
            finalIndex = nil
            movedConsonant = currentFinalScalar
        }

        // Render and seal the (now reduced) previous syllable as committed text.
        let committed = renderPreedit()

        // Reset state and start the new syllable with the moved consonant as initial
        // and the incoming vowel as medial.
        initialIndex = HangulJamoTables.compatibilityInitialIndex[movedConsonant]
        medialIndex = vIdx
        finalIndex = nil

        let newPreedit = renderPreedit()
        let diff = HangulDiff(
            backspaces: graphemeCount(priorPreedit),
            text: committed + newPreedit
        )
        lastPreedit = newPreedit
        return diff
    }

    // MARK: - Consonant input

    private func inputConsonant(_ scalar: Unicode.Scalar) -> HangulDiff {
        let priorPreedit = lastPreedit
        let initialIdx = HangulJamoTables.compatibilityInitialIndex[scalar]
        let finalIdx = HangulJamoTables.compatibilityFinalIndex[scalar]

        // Case 1: empty buffer → start a new syllable with this consonant as initial.
        if initialIndex == nil && medialIndex == nil && finalIndex == nil {
            if let idx = initialIdx {
                initialIndex = idx
                return emitPreeditDiff(priorPreedit: priorPreedit)
            }
            // Consonant can't be an initial — pass through.
            return flushAndEmit(passthrough: String(scalar))
        }

        // Case 2: have initial only (no medial yet) → can't add another initial.
        // Commit the current initial as a standalone jamo, then buffer the new one.
        if initialIndex != nil && medialIndex == nil {
            // Commit the current initial as the user typed it (Compatibility Jamo).
            let committedInit = HangulJamoTables.initialIndexToCompatibility[initialIndex!]
                .map { String($0) } ?? ""
            // Start a new initial.
            initialIndex = initialIdx
            let newPreedit = renderPreedit()
            let diff = HangulDiff(
                backspaces: graphemeCount(priorPreedit),
                text: committedInit + newPreedit
            )
            lastPreedit = newPreedit
            return diff
        }

        // Case 3: have IM (no final) → try to add as final.
        if initialIndex != nil && medialIndex != nil && finalIndex == nil {
            if let idx = finalIdx {
                finalIndex = idx
                return emitPreeditDiff(priorPreedit: priorPreedit)
            }
            // Consonant can't be a final — commit IM, start new syllable with this initial.
            return commitAndStartInitial(initialIdx: initialIdx, scalar: scalar, priorPreedit: priorPreedit)
        }

        // Case 4: have IMF → try to combine finals.
        if initialIndex != nil && medialIndex != nil && finalIndex != nil {
            let currentFinalScalar = HangulJamoTables.finalIndexToCompatibility[finalIndex!]!
            if let combined = HangulJamoTables.finalCombinations[Pair(currentFinalScalar, scalar)],
               let combinedIdx = HangulJamoTables.compatibilityFinalIndex[combined] {
                finalIndex = combinedIdx
                return emitPreeditDiff(priorPreedit: priorPreedit)
            }
            // Can't combine — commit IMF, start new syllable with this initial.
            return commitAndStartInitial(initialIdx: initialIdx, scalar: scalar, priorPreedit: priorPreedit)
        }

        // Defensive fallback.
        return flushAndEmit(passthrough: String(scalar))
    }

    /// Commit the current syllable and start a new one with the given consonant.
    private func commitAndStartInitial(initialIdx: Int?, scalar: Unicode.Scalar, priorPreedit: String) -> HangulDiff {
        let committed = renderPreedit()
        if let idx = initialIdx {
            initialIndex = idx
            medialIndex = nil
            finalIndex = nil
        } else {
            // Consonant can't be initial — commit current, pass scalar through.
            initialIndex = nil
            medialIndex = nil
            finalIndex = nil
            let payload = committed + String(scalar)
            let diff = HangulDiff(
                backspaces: graphemeCount(priorPreedit),
                text: payload
            )
            lastPreedit = ""
            return diff
        }
        let newPreedit = renderPreedit()
        let diff = HangulDiff(
            backspaces: graphemeCount(priorPreedit),
            text: committed + newPreedit
        )
        lastPreedit = newPreedit
        return diff
    }

    // MARK: - Diff helpers

    private func emitPreeditDiff(priorPreedit: String) -> HangulDiff {
        let newPreedit = renderPreedit()
        let diff = HangulDiff(
            backspaces: graphemeCount(priorPreedit),
            text: newPreedit
        )
        lastPreedit = newPreedit
        return diff
    }

    private func flushAndEmit(passthrough: String) -> HangulDiff {
        let priorPreedit = lastPreedit
        let committed = renderPreedit()
        initialIndex = nil
        medialIndex = nil
        finalIndex = nil
        lastPreedit = ""
        return HangulDiff(
            backspaces: graphemeCount(priorPreedit),
            text: committed + passthrough
        )
    }

    private func graphemeCount(_ string: String) -> Int {
        string.count
    }

    // MARK: - Rendering

    /// Render the current state to a string: either nothing, a bare Compatibility Jamo,
    /// or a precomposed Hangul Syllable (U+AC00..U+D7A3).
    private func renderPreedit() -> String {
        switch (initialIndex, medialIndex, finalIndex) {
        case (nil, nil, nil):
            return ""
        case let (i?, nil, nil):
            // Bare initial — render as Compatibility Jamo.
            if let scalar = HangulJamoTables.initialIndexToCompatibility[i] {
                return String(scalar)
            }
            return ""
        case let (nil, v?, nil):
            // Bare medial.
            if let scalar = HangulJamoTables.medialIndexToCompatibility[v] {
                return String(scalar)
            }
            return ""
        case let (i?, v?, nil):
            // Precomposed L+V syllable.
            if let scalar = HangulJamoTables.composeSyllable(initial: i, medial: v, final: 0) {
                return String(scalar)
            }
            return ""
        case let (i?, v?, f?):
            // Precomposed L+V+T syllable.
            if let scalar = HangulJamoTables.composeSyllable(initial: i, medial: v, final: f) {
                return String(scalar)
            }
            return ""
        default:
            // Pathological combinations (e.g. final without medial). Render best-effort
            // as concatenated Compatibility Jamo.
            var out = ""
            if let i = initialIndex, let s = HangulJamoTables.initialIndexToCompatibility[i] { out.append(Character(s)) }
            if let v = medialIndex, let s = HangulJamoTables.medialIndexToCompatibility[v] { out.append(Character(s)) }
            if let f = finalIndex, let s = HangulJamoTables.finalIndexToCompatibility[f] { out.append(Character(s)) }
            return out
        }
    }
}
