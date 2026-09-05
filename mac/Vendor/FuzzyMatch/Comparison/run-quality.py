#!/usr/bin/env python3
"""
Compare fuzzy matching quality across FuzzyMatcher, nucleo, RapidFuzz, and fzf.

Usage:
    python3 Comparison/run-quality.py              # run all matchers
    python3 Comparison/run-quality.py --fm         # FuzzyMatcher only
    python3 Comparison/run-quality.py --fm --nucleo # FuzzyMatcher + nucleo
    python3 Comparison/run-quality.py --ifrit      # include Ifrit (slow)

Matcher flags: --fm, --fm-ed, --fm-sw, --nucleo, --rf, --rf-wratio, --rf-partial, --fzf, --ifrit
If no matcher flags given, all are run except Ifrit (very slow, must be explicitly requested).
  --fm           Run FuzzyMatch (both Edit Distance and Smith-Waterman)
  --fm-ed        Run FuzzyMatch (Edit Distance only)
  --fm-sw        Run FuzzyMatch (Smith-Waterman only)
  --rf           Run RapidFuzz (both WRatio and PartialRatio)
  --rf-wratio    Run RapidFuzz WRatio only
  --rf-partial   Run RapidFuzz PartialRatio only
  --skip-build   Skip building harnesses (assume pre-built)
"""

import subprocess
import sys
import os
import csv
from collections import defaultdict

# --- Parse flags ---
MATCHER_FLAGS = {'--fm', '--fm-ed', '--fm-sw', '--nucleo', '--rf', '--rf-wratio', '--rf-partial', '--fzf', '--ifrit'}
given_flags = set(arg for arg in sys.argv[1:] if arg in MATCHER_FLAGS)
SKIP_BUILD = '--skip-build' in sys.argv

if not given_flags:
    # Default: all except Ifrit (very slow)
    RUN_FM_ED = True
    RUN_FM_SW = True
    RUN_NUCLEO = True
    RUN_RF_WR = True
    RUN_RF_PR = True
    RUN_FZF = True
    INCLUDE_IFRIT = False
else:
    # --fm enables both; --fm-ed / --fm-sw enable individually
    RUN_FM_ED = '--fm' in given_flags or '--fm-ed' in given_flags
    RUN_FM_SW = '--fm' in given_flags or '--fm-sw' in given_flags
    RUN_NUCLEO = '--nucleo' in given_flags
    # --rf enables both; --rf-wratio / --rf-partial enable individually
    RUN_RF_WR = '--rf' in given_flags or '--rf-wratio' in given_flags
    RUN_RF_PR = '--rf' in given_flags or '--rf-partial' in given_flags
    RUN_FZF = '--fzf' in given_flags
    INCLUDE_IFRIT = '--ifrit' in given_flags

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
TSV_FILE = os.path.join(REPO_ROOT, "Resources", "instruments-export.tsv")
QUERIES_FILE = os.path.join(REPO_ROOT, "Resources", "queries.tsv")

# Binary paths (after building)
FM_BIN = os.path.join(SCRIPT_DIR, "quality-fuzzymatch", ".build", "release", "quality-fuzzymatch")
NUCLEO_BIN = os.path.join(SCRIPT_DIR, "quality-nucleo", "target", "release", "quality-nucleo")
IFRIT_BIN = os.path.join(SCRIPT_DIR, "quality-ifrit", ".build", "release", "quality-ifrit")
RAPIDFUZZ_BIN = os.path.join(SCRIPT_DIR, "quality-rapidfuzz", "quality-rapidfuzz")
FZF_BIN = "fzf"

# Category display order — maps TSV category names to display names
CATEGORY_MAP = {
    "exact_symbol": "Exact symbol",
    "exact_name": "Exact name",
    "exact_isin": "Exact ISIN",
    "prefix": "Prefix / progressive typing",
    "typo": "Typo / misspelling",
    "substring": "Keyword / substring",
    "multi_word": "Multi-word descriptive",
    "symbol_spaces": "Symbol with spaces",
    "abbreviation": "Abbreviation (first letters)",
}

CATEGORY_ORDER = [
    "exact_symbol",
    "exact_name",
    "exact_isin",
    "prefix",
    "typo",
    "substring",
    "multi_word",
    "symbol_spaces",
    "abbreviation",
]


def load_queries(path):
    """Load queries from TSV (query, field, category[, expected_name]).

    The optional 4th column ``expected_name`` is used for ground truth
    evaluation.  When missing it defaults to ``_SKIP_``.
    """
    queries = []
    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split('\t')
            if len(parts) >= 4:
                queries.append((parts[0], parts[1], parts[2], parts[3]))
            elif len(parts) >= 3:
                queries.append((parts[0], parts[1], parts[2], '_SKIP_'))
            elif len(parts) == 2:
                # Fallback for old 2-column format
                queries.append((parts[0], parts[1], 'other', '_SKIP_'))
    return queries


def build_all():
    """Build selected harnesses."""
    if RUN_FM_ED or RUN_FM_SW:
        print("Building FuzzyMatch quality harness (release)...")
        subprocess.run(
            ["swift", "build", "-c", "release"],
            cwd=os.path.join(SCRIPT_DIR, "quality-fuzzymatch"),
            check=True, capture_output=True
        )
        print("  done")

    if RUN_NUCLEO:
        print("Building nucleo quality harness (release)...")
        subprocess.run(
            ["cargo", "build", "--release"],
            cwd=os.path.join(SCRIPT_DIR, "quality-nucleo"),
            check=True, capture_output=True
        )
        print("  done")

    if RUN_RF_WR or RUN_RF_PR:
        print("Building RapidFuzz quality harness...")
        subprocess.run(
            ["make"],
            cwd=os.path.join(SCRIPT_DIR, "quality-rapidfuzz"),
            check=True, capture_output=True
        )
        print("  done")

    if INCLUDE_IFRIT:
        print("Building Ifrit quality harness (release)...")
        subprocess.run(
            ["swift", "build", "-c", "release"],
            cwd=os.path.join(SCRIPT_DIR, "quality-ifrit"),
            check=True, capture_output=True
        )
        print("  done")

    if RUN_FZF:
        # Check fzf is available
        try:
            subprocess.run([FZF_BIN, "--version"], capture_output=True, check=True)
            print("fzf found")
        except (FileNotFoundError, subprocess.CalledProcessError):
            print("WARNING: fzf not found in PATH, fzf results will be empty")

    print()


def run_stdin_tool(binary, queries, timeout=300, extra_args=None):
    """Run a stdin-based quality harness and parse results."""
    input_data = '\n'.join(f'{q}\t{f}' for q, f, *_ in queries) + '\n'
    cmd = [binary, TSV_FILE]
    if extra_args:
        cmd.extend(extra_args)
    result = subprocess.run(
        cmd,
        input=input_data, capture_output=True, text=True, timeout=timeout
    )
    if result.returncode != 0 and result.stderr:
        print(f"  stderr: {result.stderr[:300]}", file=sys.stderr)

    results = defaultdict(list)
    for line in result.stdout.strip().split('\n'):
        if not line:
            continue
        parts = line.split('\t')
        if len(parts) >= 6:
            key = (parts[0], parts[1])
            entry = {
                'rank': int(parts[2]),
                'score': parts[3],
                'symbol': parts[-2],
                'name': parts[-1],
            }
            # FuzzyMatcher has a 'kind' field at index 4
            if len(parts) >= 7:
                entry['kind'] = parts[4]
            results[key].append(entry)
    return results


def load_tsv_data():
    """Load instruments for fzf."""
    instruments = []
    with open(TSV_FILE, 'r') as f:
        reader = csv.reader(f, delimiter='\t')
        next(reader)  # skip header
        for row in reader:
            if len(row) >= 3:
                instruments.append((row[0], row[1], row[2]))
    return instruments


def run_fzf_single(query, field, instruments):
    """Run fzf --filter for a single query."""
    if field == "symbol":
        candidates = '\n'.join(inst[0] for inst in instruments)
    elif field == "isin":
        candidates = '\n'.join(inst[2] for inst in instruments)
    else:
        candidates = '\n'.join(inst[1] for inst in instruments)

    try:
        result = subprocess.run(
            [FZF_BIN, '--filter', query],
            input=candidates, capture_output=True, text=True, timeout=30
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []

    matches = []
    seen = set()
    for line in result.stdout.strip().split('\n')[:10]:
        if not line:
            continue
        for inst in instruments:
            val = inst[0] if field == "symbol" else inst[2] if field == "isin" else inst[1]
            if val == line and val not in seen:
                seen.add(val)
                matches.append({
                    'rank': len(matches) + 1,
                    'score': '-',
                    'symbol': inst[0],
                    'name': inst[1]
                })
                break
    return matches


def run_fzf(queries, instruments):
    """Run fzf for all queries."""
    results = defaultdict(list)
    for q, f, *_ in queries:
        matches = run_fzf_single(q, f, instruments)
        results[(q, f)] = matches
    return results


def get_top1(results, key):
    """Get the top-1 result (symbol, name) for a query key, or None."""
    r = results.get(key, [])
    if r:
        return (r[0]['symbol'], r[0]['name'])
    return None


def check_ground_truth(results, key, expected, top_n):
    """Check if expected_name appears (case-insensitive substring) in any top-N result name."""
    r = results.get(key, [])
    expected_lower = expected.lower()
    for entry in r[:top_n]:
        if expected_lower in entry.get('name', '').lower():
            return True
    return False


def fmt_result(r, col_w):
    """Format a single result entry for display."""
    score = r.get('score', '-')
    sym = r.get('symbol', '')[:10]
    nm = r.get('name', '')
    max_name = col_w - len(str(score)) - len(sym) - 3
    if max_name < 5:
        max_name = 5
    if len(nm) > max_name:
        nm = nm[:max_name - 3] + '...'
    return f"{score} {sym} {nm}"


def main():
    if not os.path.isfile(TSV_FILE):
        print(f"Error: corpus file not found at {TSV_FILE}")
        sys.exit(1)
    if not os.path.isfile(QUERIES_FILE):
        print(f"Error: queries file not found at {QUERIES_FILE}")
        sys.exit(1)

    queries = load_queries(QUERIES_FILE)

    enabled = []
    if RUN_FM_ED: enabled.append('FuzzyMatcher')
    if RUN_FM_SW: enabled.append('FM(SW)')
    if RUN_NUCLEO: enabled.append('nucleo')
    if RUN_RF_WR: enabled.append('RF(WRatio)')
    if RUN_RF_PR: enabled.append('RF(Partial)')
    if RUN_FZF: enabled.append('fzf')
    if INCLUDE_IFRIT: enabled.append('Ifrit')

    print(f"Loaded {len(queries)} queries")
    print(f"Corpus: {TSV_FILE}")
    print(f"Running: {', '.join(enabled)}")
    print()

    # Build selected harnesses
    if not SKIP_BUILD:
        build_all()

    # Run selected matchers
    fm_results = defaultdict(list)
    fm_sw_results = defaultdict(list)
    nucleo_results = defaultdict(list)
    rapidfuzz_wr_results = defaultdict(list)
    rapidfuzz_pr_results = defaultdict(list)
    ifrit_results = defaultdict(list)
    fzf_results = defaultdict(list)

    if RUN_FM_ED:
        print("Running FuzzyMatcher (Edit Distance)...", flush=True)
        fm_results = run_stdin_tool(FM_BIN, queries)
        print(f"  Got results for {len(fm_results)} queries")

    if RUN_FM_SW:
        print("Running FuzzyMatcher (Smith-Waterman)...", flush=True)
        fm_sw_results = run_stdin_tool(FM_BIN, queries, extra_args=["--sw"])
        print(f"  Got results for {len(fm_sw_results)} queries")

    if RUN_NUCLEO:
        print("Running nucleo...", flush=True)
        nucleo_results = run_stdin_tool(NUCLEO_BIN, queries)
        print(f"  Got results for {len(nucleo_results)} queries")

    if RUN_RF_WR:
        print("Running RapidFuzz (WRatio)...", flush=True)
        rapidfuzz_wr_results = run_stdin_tool(RAPIDFUZZ_BIN, queries)
        print(f"  Got results for {len(rapidfuzz_wr_results)} queries")

    if RUN_RF_PR:
        print("Running RapidFuzz (PartialRatio)...", flush=True)
        rapidfuzz_pr_results = run_stdin_tool(RAPIDFUZZ_BIN, queries, extra_args=["--scorer", "partial_ratio"])
        print(f"  Got results for {len(rapidfuzz_pr_results)} queries")

    if INCLUDE_IFRIT:
        print("Running Ifrit (Fuse)...", flush=True)
        ifrit_results = run_stdin_tool(IFRIT_BIN, queries, timeout=600)
        print(f"  Got results for {len(ifrit_results)} queries")

    if RUN_FZF:
        print("Loading instruments for fzf...", flush=True)
        instruments = load_tsv_data()
        print(f"  Loaded {len(instruments)} instruments")
        print("Running fzf (this may take a while)...", flush=True)
        fzf_results = run_fzf(queries, instruments)
        print(f"  Got results for {len(fzf_results)} queries")
    else:
        instruments = []

    print()

    # ─── Save individual results to /tmp for parallel collation ───
    import json as _json

    def _save_results_to_tmp(name, results, queries):
        """Save per-matcher results to /tmp/quality-{name}-latest.json."""
        tag = {
            'FuzzyMatcher': 'fuzzymatch',
            'FM(SW)': 'fuzzymatch-sw',
            'nucleo': 'nucleo',
            'RF(WRatio)': 'rapidfuzz-wratio',
            'RF(Partial)': 'rapidfuzz-partial',
            'fzf': 'fzf',
            'Ifrit': 'ifrit',
        }.get(name, name.lower().replace(' ', '-'))
        path = f"/tmp/quality-{tag}-latest.json"
        data = {}
        for (q, f), entries in results.items():
            key = f"{q}\t{f}"
            data[key] = entries
        with open(path, 'w') as fp:
            _json.dump(data, fp)

    if RUN_FM_ED: _save_results_to_tmp('FuzzyMatcher', fm_results, queries)
    if RUN_FM_SW: _save_results_to_tmp('FM(SW)', fm_sw_results, queries)
    if RUN_NUCLEO: _save_results_to_tmp('nucleo', nucleo_results, queries)
    if RUN_RF_WR: _save_results_to_tmp('RF(WRatio)', rapidfuzz_wr_results, queries)
    if RUN_RF_PR: _save_results_to_tmp('RF(Partial)', rapidfuzz_pr_results, queries)
    if INCLUDE_IFRIT: _save_results_to_tmp('Ifrit', ifrit_results, queries)
    if RUN_FZF: _save_results_to_tmp('fzf', fzf_results, queries)

    # ─── Build dynamic tool list ───

    # Map of name -> results dict (ordered)
    all_results = {}
    if RUN_FM_ED: all_results['FuzzyMatcher'] = fm_results
    if RUN_FM_SW: all_results['FM(SW)'] = fm_sw_results
    if RUN_NUCLEO: all_results['nucleo'] = nucleo_results
    if RUN_RF_WR: all_results['RF(WRatio)'] = rapidfuzz_wr_results
    if RUN_RF_PR: all_results['RF(Partial)'] = rapidfuzz_pr_results
    if INCLUDE_IFRIT: all_results['Ifrit'] = ifrit_results
    if RUN_FZF: all_results['fzf'] = fzf_results

    tool_names = list(all_results.keys())
    num_tools = len(tool_names)

    col_w = 34
    total_w = 6 + col_w * num_tools + 12
    sep = "=" * total_w

    print(sep)
    print("FUZZY MATCHING QUALITY COMPARISON")
    print(sep)
    if instruments:
        print(f"Corpus: {len(instruments)} instruments")
    print(f"Queries: {len(queries)}")
    print(f"Matchers: {', '.join(tool_names)}")
    print()

    # Summary stats
    result_counts = {}
    for name, res in all_results.items():
        count = sum(1 for q, f, *_ in queries if res.get((q, f)))
        result_counts[name] = count

    counts_str = "  ".join(f"{n}={c}/{len(queries)}" for n, c in result_counts.items())
    print(f"Queries with results:  {counts_str}")
    print()

    # ─── Per-category detail ───

    # Group queries by category
    by_category = defaultdict(list)
    for q, f, cat, *_ in queries:
        by_category[cat].append((q, f))

    def print_query_block(q, f):
        key = (q, f)
        tool_results = {name: res.get(key, []) for name, res in all_results.items()}

        print(f"\n  Query: \"{q}\" (field: {f})")
        print(f"  {'─' * (total_w - 4)}")
        header = f"  {'Rank':<6}"
        for name in tool_names:
            header += f" {name:<{col_w}}"
        print(header)
        print(f"  {'─' * (total_w - 4)}")

        max_rows = max((len(v) for v in tool_results.values()), default=1)
        max_rows = min(max_rows, 5)  # Show top 5

        for i in range(max_rows):
            row = f"  {i+1:<6}"
            for name in tool_names:
                matches = tool_results[name]
                if i < len(matches):
                    if name == 'fzf':
                        sym = matches[i].get('symbol', '')[:10]
                        nm = matches[i].get('name', '')
                        if len(nm) > 20:
                            nm = nm[:17] + '...'
                        cell = f"{sym} {nm}"
                    else:
                        cell = fmt_result(matches[i], col_w)
                else:
                    cell = ""
                row += f" {cell:<{col_w}}"
            print(row)

        if all(len(v) == 0 for v in tool_results.values()):
            nr = "(no results)"
            row = f"  {'—':<6}"
            for _ in tool_names:
                row += f" {nr:<{col_w}}"
            print(row)

    # Collect all categories present in queries
    seen_categories = set(cat for _, _, cat, *_ in queries)

    for cat in CATEGORY_ORDER:
        cat_queries = by_category.get(cat, [])
        if not cat_queries:
            continue
        display_name = CATEGORY_MAP.get(cat, cat)
        print(f"\n{'─' * total_w}")
        print(f"  {display_name} ({len(cat_queries)} queries)")
        print(f"{'─' * total_w}")

        for q, f in cat_queries:
            print_query_block(q, f)

    # Print uncategorized (categories not in CATEGORY_ORDER)
    other_cats = [c for c in seen_categories if c not in CATEGORY_ORDER]
    for cat in sorted(other_cats):
        cat_queries = by_category.get(cat, [])
        if not cat_queries:
            continue
        display_name = CATEGORY_MAP.get(cat, cat)
        print(f"\n{'─' * total_w}")
        print(f"  {display_name} ({len(cat_queries)} queries)")
        print(f"{'─' * total_w}")
        for q, f in cat_queries:
            print_query_block(q, f)

    # ─── Category summary table ───

    print(f"\n{sep}")
    print("CATEGORY SUMMARY — Top-1 Agreement")
    print(sep)
    print()

    if num_tools >= 2:
        # Build pairwise column headers: first tool vs each other
        ref_name = tool_names[0]
        pair_headers = [f"{ref_name[:2]}={n[:3]}" for n in tool_names[1:]]
        header = f"{'Category':<30} {'Queries':>7}"
        for ph in pair_headers:
            header += f"  {ph:>6}"
        header += f"  {'All agree':>9}"
        print(header)
        print("─" * len(header))

        all_category_keys = CATEGORY_ORDER + sorted(other_cats)
        for cat in all_category_keys:
            cat_queries = by_category.get(cat, [])
            if not cat_queries:
                continue

            display_name = CATEGORY_MAP.get(cat, cat)
            n = len(cat_queries)
            ref_res = all_results[ref_name]
            pair_counts = [0] * (num_tools - 1)
            all_agree = 0

            for q, f in cat_queries:
                key = (q, f)
                ref_top = get_top1(ref_res, key)
                tops = []
                for idx, name in enumerate(tool_names):
                    t = get_top1(all_results[name], key)
                    tops.append(t)
                    if idx > 0 and ref_top and t and ref_top == t:
                        pair_counts[idx - 1] += 1
                if all(t is not None for t in tops) and len(set(tops)) == 1:
                    all_agree += 1

            row = f"{display_name:<30} {n:>7}"
            for pc in pair_counts:
                row += f"  {pc:>3}/{n:<3}"
            row += f"  {all_agree:>4}/{n}"
            print(row)
    else:
        print("(Need at least 2 matchers for agreement comparison)")

    # ─── Ground truth evaluation ───

    # Build query lookup: (q, f) -> (category, expected_name)
    query_meta = {}
    for q, f, cat, expected in queries:
        query_meta[(q, f)] = (cat, expected)

    # Count evaluated (non-SKIP) queries per category
    eval_by_category = defaultdict(list)  # cat -> [(q, f, expected)]
    for (q, f), (cat, expected) in query_meta.items():
        if expected != '_SKIP_':
            eval_by_category[cat].append((q, f, expected))

    total_evaluated = sum(len(v) for v in eval_by_category.values())

    if total_evaluated > 0:
        print(f"\n{sep}")
        print("GROUND TRUTH EVALUATION — Top-1 (Top-5 for typo)")
        print(sep)
        print()

        # Build header
        gt_header = f"{'Category':<30} {'Queries':>7}"
        for name in tool_names:
            gt_header += f"  {name:>14}"
        print(gt_header)
        print("─" * len(gt_header))

        # Per-category ground truth
        gt_totals = {name: 0 for name in tool_names}
        gt_total_queries = 0
        all_category_keys = CATEGORY_ORDER + sorted(
            c for c in eval_by_category if c not in CATEGORY_ORDER
        )
        for cat in all_category_keys:
            entries = eval_by_category.get(cat, [])
            if not entries:
                continue
            display_name = CATEGORY_MAP.get(cat, cat)
            top_n = 5 if cat in ('typo', 'prefix', 'abbreviation') else 1
            if cat in ('typo', 'prefix', 'abbreviation'):
                display_name += ' (top-5)'
            n = len(entries)
            gt_total_queries += n
            row = f"{display_name:<30} {n:>7}"
            for name in tool_names:
                res = all_results[name]
                hits = sum(
                    1 for q, f, expected in entries
                    if check_ground_truth(res, (q, f), expected, top_n)
                )
                gt_totals[name] += hits
                pct = hits * 100 // n if n else 0
                row += f"  {hits:>3}/{n} {pct:>3}%"
            print(row)

        # Total row
        row = f"{'TOTAL':<30} {gt_total_queries:>7}"
        for name in tool_names:
            hits = gt_totals[name]
            pct = hits * 100 // gt_total_queries if gt_total_queries else 0
            row += f"  {hits:>3}/{gt_total_queries} {pct:>3}%"
        print("─" * len(gt_header))
        print(row)
        print()
        print(f"Note: {len(queries) - total_evaluated} queries skipped (_SKIP_): exact_symbol, symbol_spaces, short prefix.")
        print(f"Typo, prefix, and abbreviation categories use top-5 (correct result in first 5); all others use top-1.")

    # ─── Overall summary ───

    print(f"\n{sep}")
    print("OVERALL SUMMARY")
    print(sep)
    print()
    print(f"{'Metric':<45} {'Count':>10}")
    print("─" * 57)

    for name, count in result_counts.items():
        print(f"{'Queries returning results (' + name + ')':<45} {count:>5}/{len(queries)}")

    print()

    # Pairwise top-1 agreement (all pairs)
    if num_tools >= 2:
        tool_list = list(all_results.items())
        for i in range(len(tool_list)):
            for j in range(i + 1, len(tool_list)):
                name_a, res_a = tool_list[i]
                name_b, res_b = tool_list[j]
                count = 0
                for q, f, *_ in queries:
                    a = get_top1(res_a, (q, f))
                    b = get_top1(res_b, (q, f))
                    if a and b and a == b:
                        count += 1
                label = f"Top-1 agreement {name_a} vs {name_b}"
                print(f"{label:<45} {count:>5}/{len(queries)}")

        # All tools agree
        all_match = 0
        for q, f, *_ in queries:
            key = (q, f)
            tops = [get_top1(r, key) for _, r in tool_list]
            if all(t is not None for t in tops) and len(set(tops)) == 1:
                all_match += 1
        print(f"{'All ' + str(num_tools) + ' agree on top-1':<45} {all_match:>5}/{len(queries)}")

        # N-1 way agreements (exclude one tool at a time)
        if num_tools >= 3:
            print()
            for excluded_name, excluded_res in tool_list:
                others = [(n, r) for n, r in tool_list if r is not excluded_res]
                count = 0
                for q, f, *_ in queries:
                    key = (q, f)
                    tops = [get_top1(r, key) for _, r in others]
                    if all(t is not None for t in tops) and len(set(tops)) == 1:
                        count += 1
                other_names = ' + '.join(n for n, _ in others)
                label = f"{other_names} agree"
                print(f"{label:<45} {count:>5}/{len(queries)}")

    print()

    # Print saved file locations
    print("Quality results saved to:")
    if RUN_FM_ED: print("  /tmp/quality-fuzzymatch-latest.json")
    if RUN_FM_SW: print("  /tmp/quality-fuzzymatch-sw-latest.json")
    if RUN_NUCLEO: print("  /tmp/quality-nucleo-latest.json")
    if RUN_RF_WR: print("  /tmp/quality-rapidfuzz-wratio-latest.json")
    if RUN_RF_PR: print("  /tmp/quality-rapidfuzz-partial-latest.json")
    if INCLUDE_IFRIT: print("  /tmp/quality-ifrit-latest.json")
    if RUN_FZF: print("  /tmp/quality-fzf-latest.json")


if __name__ == '__main__':
    main()
