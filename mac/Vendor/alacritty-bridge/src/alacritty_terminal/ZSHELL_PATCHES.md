Source: alacritty_terminal 0.26.0 (crates.io), Apache-2.0; full license is LICENSE-APACHE.
Local changes in src/term/cell.rs and src/term/mod.rs, plus src/term/command.rs and
src/event.rs, retain bounded OSC 133 metadata and a few native cell anchors.
Prompt and input text tags are only allocated at a shell prompt; output cells are unchanged.
Prompt tags and continuation anchors also let the renderer avoid extending formatted
prompt backgrounds vertically into terminal padding.
Alternate-screen OSC 133 prompt anchors are rendering metadata only and never
produce shell-history records.
Native cell copying, erasure, insertion, deletion and reflow preserve or invalidate anchors. Resolved
positions are cached by grid revision, including resize and bridge grid access.
The native renderer reads explicitly recorded grid damage without manufacturing
idle cursor or insert-mode damage. Actual writes and raw grid mutations retain
their invalidation; the bridge and host track cursor state and visibility.
The crate uses the adjacent local vte copy for native OSC 7/133 callbacks.
The crate is nested under the bridge's src so its existing sandbox-safe source-copy
build phases include it. Reference-test fixtures are not vendored; their manifest
entry is omitted. No terminal executor or renderer is duplicated.
