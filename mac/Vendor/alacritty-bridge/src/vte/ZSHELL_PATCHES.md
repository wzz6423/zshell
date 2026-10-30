Source: vte 0.15.0, MIT or Apache-2.0. Both licenses are retained.
Only src/ansi.rs differs: OSC 7 and OSC 133 dispatch through Handler callbacks at the native VT boundary, including synchronized updates. No second VT parser is used.
