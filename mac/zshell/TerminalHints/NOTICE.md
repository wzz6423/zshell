# Terminal hint sources

`TerminalHintMatcher.swift` directly adapts the `PATTERNS` array and
`compute_labels_for_alphabet` implementation from Kaku:

- Repository: https://github.com/tw93/Kaku
- Revision: `82477d547ee80bf9040f4bc217f2d002c5da2423`
- Source: `kaku-gui/src/overlay/quickselect.rs`
- Copyright (c) 2024-Present Tw93
- Copyright (c) 2018-Present Wez Furlong (original WezTerm code)
- Complete license: `LICENSE-Kaku.md` (MIT)

Kaku attributes its label algorithm to tmux-thumbs:

- Repository: https://github.com/fcsonline/tmux-thumbs
- Source: `src/alphabets.rs`
- Copyright (c) 2019 Ferran Basora
- License inspected at revision: `ae91d5f7c0d989933e86409833c46a1eca521b6a`
- Complete license: `LICENSE-tmux-thumbs.txt` (MIT)

Zshell's adaptation preserves the original pattern order and label allocation,
adds local diagnostic suffixes and bare hosts, merges soft-wrapped visible rows,
and uses an AppKit overlay over backend-neutral viewport cell coordinates.
These notices and complete licenses ship in the application bundle.
