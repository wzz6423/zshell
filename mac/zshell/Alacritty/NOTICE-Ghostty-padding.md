# Terminal padding source

`TerminalMetalRenderer.swift` adapts the padding extension heuristics from
Ghostty's `src/renderer/row.zig` and the edge clamping behavior from
`src/renderer/shaders/shaders.metal`:

- Repository: https://github.com/ghostty-org/ghostty
- Revision: `35e1a0160c4f6797e1bb1ef8e7a2b8c6b114ab58`
- Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
- Complete license: `LICENSE-Ghostty.txt` (MIT)

The Alacritty adaptation uses Zshell's retained background quads and native
OSC 133 cell metadata. The Ghostty backend uses the same pinned engine directly.
`TerminalPaddingBackground.swift` preserves that engine's physical-pixel padding
balance and works around retained extension flags during live switches by
cropping the existing IOSurface through Core Animation. It copies no pixels and
keeps the original grid, PTY, selection and input geometry.
This notice and complete license ship in the application bundle.
