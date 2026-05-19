# HangulSwift

A small, license-clean Hangul (한글) composer state machine for SwiftTerm.

## What it does

Accepts one Compatibility Jamo (U+3131..U+318E) at a time — the form iOS Korean keyboards
emit through `insertText(_:)` — and produces a `HangulDiff` describing how the host should
update its display:

```swift
let composer = HangulComposer()
composer.input("ㄱ")  // → diff: text "ㄱ"
composer.input("ㅏ")  // → diff: erase 1, text "가"
composer.input("ㄴ")  // → diff: erase 1, text "간"
composer.input("ㄴ")  // → diff: erase 1, text "간ㄴ"  (final promotion: "간" sealed, ㄴ becomes next initial)
```

The composer is the engine for the SwiftTerm Korean IME path. It replaces the brittle
`tryComposeKoreanFinal` heuristic in `iOSTerminalView.swift` (which only handled receding
finals) with a complete two-set (두벌식) state machine: initial + medial + final slots,
medial combinations (ㅗ+ㅏ → ㅘ), final combinations (ㄱ+ㅅ → ㄳ), and final promotion.

## Why a separate module

- **License-clean.** The reference implementation (libhangul) is LGPL-2.1. We could not
  static-link it into SwiftTerm without imposing LGPL obligations on every downstream
  user (CodeEdit, Secure Shellfish, Pane, …). Instead, this module is a clean-room
  reconstruction from the Unicode Standard (chapter 18.6, Hangul Syllables).
- **Decoupled from terminal state.** The composer has no knowledge of PTY, terminal
  buffers, or ANSI escapes. It emits abstract diffs (backspace count + text). The
  `iOSTerminalView.swift` integration layer translates those diffs into PTY bytes.

## API

- `HangulComposer.input(scalar:)` — feed one jamo, get back a `HangulDiff`.
- `HangulComposer.backspace()` — step state back one logical unit.
- `HangulComposer.flush()` — commit any in-progress syllable.
- `HangulComposer.reset()` — discard state (e.g. focus loss).
- `HangulComposer.isHangulJamo(_:)` — static check whether a scalar is a Compatibility Jamo.

## What it does NOT do

- 옛한글 (Yet Hangul / pre-1933 letters in U+11xx, U+A960, U+D7Bxx). Modern Hangul only.
- 세벌식 (3-set) keyboard layouts. iOS standard keyboard is 두벌식; this matches.
- Hanja (한자) conversion. Out of scope.
- Width-aware backspace translation. The integration layer handles column counting.

## License

MIT, same as SwiftTerm. See `LICENSE` at the repo root.

The composition algorithm is reconstructed from the Unicode Standard, which is freely
implementable. No code or data was copied from libhangul, kime, ibus-hangul, or any
other licensed Hangul library.
