# Security Policy

## Scope

FuzzyMatcher is a pure computation library — it performs string matching in memory with no network access, file I/O, or persistent storage. It does not process untrusted input from external sources by default; the caller controls what strings are passed for matching.

## Potential Concerns

- **Denial of service**: Very long strings or adversarial inputs could cause excessive computation time. The prefiltering pipeline and edit distance bounds mitigate this, but callers processing untrusted input should enforce their own length limits.
- **Memory usage**: The `ScoringBuffer` grows to accommodate the largest candidate seen. Callers can periodically create fresh buffers to reclaim memory.

## Reporting a Vulnerability

If you discover a security issue, please open a GitHub issue on the project describing the concern.

We aim to respond within 30 days for confirmed vulnerabilities.

## Fuzz Testing

The library is continuously fuzz-tested using libFuzzer with AddressSanitizer, validating that no input combination causes crashes, out-of-bounds access, or invariant violations. See [Fuzz Testing](Documentation/DAMERAU_LEVENSHTEIN.md#fuzz-testing) for details.
