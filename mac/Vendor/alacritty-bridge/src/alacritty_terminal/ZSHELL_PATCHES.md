Source: alacritty_terminal 0.26.0 (crates.io), Apache-2.0; full license is LICENSE-APACHE.
Local changes in src/term/cell.rs and src/term/mod.rs, plus src/term/command.rs and
src/event.rs, retain bounded OSC 133 metadata and a few native cell anchors.
Input text tags are only allocated at an editable prompt; output cells are unchanged.
Native cell copying, erasure and reflow preserve or invalidate anchors. Resolved
positions are cached by grid revision, including resize and bridge grid access.
The crate uses the adjacent local vte copy for native OSC 7/133 callbacks.
The crate is nested under the bridge's src so its existing sandbox-safe source-copy
build phases include it. Reference-test fixtures are not vendored; their manifest
entry is omitted. No terminal executor or renderer is duplicated.
