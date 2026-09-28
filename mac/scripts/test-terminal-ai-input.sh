#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/zshell-input-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

swiftc -parse-as-library \
    "$repo_root/mac/zshell/TerminalAIInput.swift" \
    "$repo_root/mac/tests/TerminalAIInputTests.swift" \
    -o "$test_dir/terminal-ai-input-tests"
"$test_dir/terminal-ai-input-tests"
