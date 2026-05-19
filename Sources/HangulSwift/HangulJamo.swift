//
// HangulJamo.swift — Hangul (한글) Compatibility Jamo + Conjoining Jamo tables and classification.
//
// Independent clean-room implementation based on the Unicode Standard 16.0 (chapter 18.6
// "Hangul Syllables"). No code or data was copied from libhangul (LGPL-2.1) or any other
// licensed Hangul library; the algorithms here are direct translations of the Unicode tables.
//
// All public surfaces are MIT-licensed (the SwiftTerm umbrella).
//

import Foundation

/// Jamo (자모) role within a Hangul syllable.
///
/// A Hangul syllable is composed of up to three slots:
/// - `initial` (초성, L) — leading consonant (always present, U+1100 set)
/// - `medial`  (중성, V) — vowel (always present, U+1161 set)
/// - `final`   (종성, T) — trailing consonant (optional, U+11A8 set or absent)
///
/// `isolated` is used while a consonant has arrived but has not yet been claimed as
/// either `initial` or `final` (the role depends on whether a vowel follows).
public enum HangulJamoRole: Sendable {
    case initial
    case medial
    case final
    case isolated
}

/// A single jamo character normalized to its Compatibility Jamo scalar (U+3131..U+3163).
///
/// The Hangul Compatibility Jamo block (U+3130..U+318F) is what iOS Korean keyboards
/// emit via `insertText(_:)` when the IME path falls back to raw input — the same block
/// users see on the keycaps. We use it as the canonical jamo representation throughout
/// the composer and convert to/from Conjoining Jamo (U+1100..U+11FF) only when assembling
/// a precomposed syllable.
public struct HangulJamo: Hashable, Sendable {
    public let scalar: Unicode.Scalar

    public init?(_ scalar: Unicode.Scalar) {
        guard HangulJamoTables.isCompatibilityJamo(scalar) else { return nil }
        self.scalar = scalar
    }

    /// True when this jamo is a vowel (ㅏ..ㅣ, U+314F..U+3163).
    public var isVowel: Bool {
        HangulJamoTables.isVowel(scalar)
    }

    /// True when this jamo can appear as an initial consonant (초성).
    public var canBeInitial: Bool {
        HangulJamoTables.compatibilityInitialIndex[scalar] != nil
    }

    /// True when this jamo can appear as a trailing consonant (종성).
    public var canBeFinal: Bool {
        HangulJamoTables.compatibilityFinalIndex[scalar] != nil
    }
}

enum HangulJamoTables {
    // MARK: - Range checks

    static let compatibilityJamoRange: ClosedRange<UInt32> = 0x3131...0x318E
    static let vowelRange: ClosedRange<UInt32> = 0x314F...0x3163

    static func isCompatibilityJamo(_ scalar: Unicode.Scalar) -> Bool {
        compatibilityJamoRange.contains(scalar.value)
    }

    static func isVowel(_ scalar: Unicode.Scalar) -> Bool {
        vowelRange.contains(scalar.value)
    }

    // MARK: - Initial (초성) table — 19 entries, index 0..18

    /// Compatibility-jamo scalar → initial (L) index.
    /// Source: Unicode Standard Table 4-10 "Hangul Initial Jamos".
    static let compatibilityInitialIndex: [Unicode.Scalar: Int] = [
        "ㄱ": 0,  "ㄲ": 1,  "ㄴ": 2,  "ㄷ": 3,  "ㄸ": 4,
        "ㄹ": 5,  "ㅁ": 6,  "ㅂ": 7,  "ㅃ": 8,  "ㅅ": 9,
        "ㅆ": 10, "ㅇ": 11, "ㅈ": 12, "ㅉ": 13, "ㅊ": 14,
        "ㅋ": 15, "ㅌ": 16, "ㅍ": 17, "ㅎ": 18,
    ]

    /// Initial (L) index → compatibility-jamo scalar (inverse of `compatibilityInitialIndex`).
    static let initialIndexToCompatibility: [Int: Unicode.Scalar] = Dictionary(
        uniqueKeysWithValues: compatibilityInitialIndex.map { ($0.value, $0.key) }
    )

    // MARK: - Medial (중성) table — 21 entries, index 0..20

    /// Compatibility-jamo scalar → medial (V) index.
    /// Source: Unicode Standard Table 4-11 "Hangul Medial Jamos".
    static let compatibilityMedialIndex: [Unicode.Scalar: Int] = [
        "ㅏ": 0,  "ㅐ": 1,  "ㅑ": 2,  "ㅒ": 3,  "ㅓ": 4,
        "ㅔ": 5,  "ㅕ": 6,  "ㅖ": 7,  "ㅗ": 8,  "ㅘ": 9,
        "ㅙ": 10, "ㅚ": 11, "ㅛ": 12, "ㅜ": 13, "ㅝ": 14,
        "ㅞ": 15, "ㅟ": 16, "ㅠ": 17, "ㅡ": 18, "ㅢ": 19,
        "ㅣ": 20,
    ]

    static let medialIndexToCompatibility: [Int: Unicode.Scalar] = Dictionary(
        uniqueKeysWithValues: compatibilityMedialIndex.map { ($0.value, $0.key) }
    )

    // MARK: - Final (종성) table — 27 entries, indices 1..27 (0 == no final)

    /// Compatibility-jamo scalar → final (T) index. Index 0 is reserved for "no final".
    /// Source: Unicode Standard Table 4-12 "Hangul Final Jamos".
    static let compatibilityFinalIndex: [Unicode.Scalar: Int] = [
        "ㄱ": 1,  "ㄲ": 2,  "ㄳ": 3,  "ㄴ": 4,  "ㄵ": 5,
        "ㄶ": 6,  "ㄷ": 7,  "ㄹ": 8,  "ㄺ": 9,  "ㄻ": 10,
        "ㄼ": 11, "ㄽ": 12, "ㄾ": 13, "ㄿ": 14, "ㅀ": 15,
        "ㅁ": 16, "ㅂ": 17, "ㅄ": 18, "ㅅ": 19, "ㅆ": 20,
        "ㅇ": 21, "ㅈ": 22, "ㅊ": 23, "ㅋ": 24, "ㅌ": 25,
        "ㅍ": 26, "ㅎ": 27,
    ]

    static let finalIndexToCompatibility: [Int: Unicode.Scalar] = Dictionary(
        uniqueKeysWithValues: compatibilityFinalIndex.map { ($0.value, $0.key) }
    )

    // MARK: - Medial combinations (e.g. ㅗ+ㅏ → ㅘ)

    /// `(left, right) → combined medial`. Used when a vowel arrives while the buffer already
    /// holds a medial.
    static let medialCombinations: [Pair: Unicode.Scalar] = [
        Pair("ㅗ", "ㅏ"): "ㅘ",
        Pair("ㅗ", "ㅐ"): "ㅙ",
        Pair("ㅗ", "ㅣ"): "ㅚ",
        Pair("ㅜ", "ㅓ"): "ㅝ",
        Pair("ㅜ", "ㅔ"): "ㅞ",
        Pair("ㅜ", "ㅣ"): "ㅟ",
        Pair("ㅡ", "ㅣ"): "ㅢ",
    ]

    /// Inverse of `medialCombinations`: combined medial → (left, right). Used by backspace
    /// to decompose `ㅘ` back into `ㅗ` (and let the user re-type `ㅏ`).
    static let medialDecomposition: [Unicode.Scalar: (Unicode.Scalar, Unicode.Scalar)] = {
        var map: [Unicode.Scalar: (Unicode.Scalar, Unicode.Scalar)] = [:]
        for (pair, combined) in medialCombinations {
            map[combined] = (pair.left, pair.right)
        }
        return map
    }()

    // MARK: - Final combinations (e.g. ㄱ+ㅅ → ㄳ)

    static let finalCombinations: [Pair: Unicode.Scalar] = [
        Pair("ㄱ", "ㅅ"): "ㄳ",
        Pair("ㄴ", "ㅈ"): "ㄵ",
        Pair("ㄴ", "ㅎ"): "ㄶ",
        Pair("ㄹ", "ㄱ"): "ㄺ",
        Pair("ㄹ", "ㅁ"): "ㄻ",
        Pair("ㄹ", "ㅂ"): "ㄼ",
        Pair("ㄹ", "ㅅ"): "ㄽ",
        Pair("ㄹ", "ㅌ"): "ㄾ",
        Pair("ㄹ", "ㅍ"): "ㄿ",
        Pair("ㄹ", "ㅎ"): "ㅀ",
        Pair("ㅂ", "ㅅ"): "ㅄ",
    ]

    static let finalDecomposition: [Unicode.Scalar: (Unicode.Scalar, Unicode.Scalar)] = {
        var map: [Unicode.Scalar: (Unicode.Scalar, Unicode.Scalar)] = [:]
        for (pair, combined) in finalCombinations {
            map[combined] = (pair.left, pair.right)
        }
        return map
    }()

    /// Composite finals that can _start_ a new initial after promotion. For example, when
    /// the buffer holds 갃 (가 + ㄳ) and a vowel arrives, the second part of the ㄳ cluster
    /// (ㅅ) moves to the next syllable's initial. This table maps `combined → (kept, moved)`.
    static let finalSplitForPromotion: [Unicode.Scalar: (Unicode.Scalar, Unicode.Scalar)] = finalDecomposition

    // MARK: - Helpers

    /// Convenience: build a precomposed syllable from L/V/T indices.
    /// Returns `nil` if any index is out of range.
    static func composeSyllable(initial: Int, medial: Int, final: Int) -> Unicode.Scalar? {
        guard (0...18).contains(initial), (0...20).contains(medial), (0...27).contains(final) else { return nil }
        let value: UInt32 = 0xAC00 + UInt32(initial) * 588 + UInt32(medial) * 28 + UInt32(final)
        return Unicode.Scalar(value)
    }
}

/// Ordered jamo pair for table keys.
struct Pair: Hashable {
    let left: Unicode.Scalar
    let right: Unicode.Scalar

    init(_ left: Unicode.Scalar, _ right: Unicode.Scalar) {
        self.left = left
        self.right = right
    }
}

private extension Dictionary where Key == Unicode.Scalar, Value == Int {
    subscript(_ char: Character) -> Int? {
        guard let scalar = char.unicodeScalars.first, char.unicodeScalars.count == 1 else { return nil }
        return self[scalar]
    }
}

private extension Unicode.Scalar {
    init(extendedGraphemeClusterLiteral value: String) {
        guard value.unicodeScalars.count == 1, let scalar = value.unicodeScalars.first else {
            preconditionFailure("HangulJamo dictionary literal must be a single Unicode scalar: \(value)")
        }
        self = scalar
    }
}
