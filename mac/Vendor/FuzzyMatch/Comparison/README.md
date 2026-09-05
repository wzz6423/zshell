# Comparison Suite

Performance and quality comparison of FuzzyMatch against other fuzzy matching libraries.

## Compared Libraries

- **FuzzyMatch** (edit distance mode) — this library
- **FuzzyMatch** (Smith-Waterman mode) — this library, `--sw` flag
- **[nucleo](https://github.com/helix-editor/nucleo)** (Rust) — used by Helix editor
- **[RapidFuzz](https://github.com/rapidfuzz/rapidfuzz-cpp)** (C++) — popular cross-language fuzzy matcher
- **[fzf](https://github.com/junegunn/fzf)** (Go) — quality comparison only
- **[Ifrit](https://github.com/nicklama/ifrit)** (Swift) — excluded from default runs due to slow runtime

## Prerequisites

- **Rust** (for nucleo): `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
- **rapidfuzz-cpp** (for RapidFuzz): `brew install rapidfuzz-cpp`
- **fzf** (for quality comparison): `brew install fzf`

## Running Benchmarks

```bash
# Full comparison (FuzzyMatch ED + SW, nucleo, RapidFuzz)
bash Comparison/run-benchmarks.sh --fm --sw --nucleo --rf

# Quick: FuzzyMatch vs nucleo only
bash Comparison/run-benchmarks.sh --fm --nucleo

# Include Ifrit (very slow)
bash Comparison/run-benchmarks.sh --ifrit
```

## Running Quality Comparison

```bash
# Full quality comparison
python3 Comparison/run-quality.py --fm --sw --nucleo --rf --fzf

# Include Ifrit
python3 Comparison/run-quality.py --ifrit
```

## Output

Results are printed to stdout as formatted tables. During release preparation, these tables are copied into [COMPARISON.md](../Documentation/COMPARISON.md). All queries are loaded from [`Resources/queries.tsv`](../Resources/queries.tsv) at runtime.
