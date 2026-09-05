# Examples

## fuzzygrep

A command-line fuzzy grep tool that reads lines from stdin and prints matches ranked by score. Demonstrates FuzzyMatch's parallel scoring pipeline with concurrent chunk processing.

### Build

```bash
swift build --package-path Examples -c release
```

### Usage

```bash
# Fuzzy search the system dictionary (edit distance mode, 0.5 score required)
cat /usr/share/dict/words | Examples/.build/release/fuzzygrep color

# Smith-Waterman mode
cat /usr/share/dict/words | Examples/.build/release/fuzzygrep color --sw
```
