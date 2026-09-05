use nucleo_matcher::pattern::{AtomKind, CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};
use std::cmp::Reverse;
use std::collections::BinaryHeap;
use std::env;
use std::fs;
use std::path::PathBuf;
use std::time::Instant;

const TOP_K: usize = 100;

struct Instrument {
    symbol: String,
    name: String,
    isin: String,
}

struct Query {
    text: String,
    field: String,
    category: String,
}

fn load_queries(path: &str) -> Vec<Query> {
    let content = fs::read_to_string(path).expect("Failed to read queries TSV file");
    let mut queries = Vec::new();
    for line in content.lines() {
        if line.is_empty() {
            continue;
        }
        let cols: Vec<&str> = line.split('\t').collect();
        if cols.len() >= 3 {
            queries.push(Query {
                text: cols[0].to_string(),
                field: cols[1].to_string(),
                category: cols[2].to_string(),
            });
        }
    }
    queries
}

fn main() {
    // Resolve paths from arguments
    let args: Vec<String> = env::args().collect();
    let tsv_path = if let Some(idx) = args.iter().position(|a| a == "--tsv") {
        args.get(idx + 1)
            .expect("--tsv requires a path argument")
            .clone()
    } else {
        let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        manifest_dir
            .join("../../Resources/instruments-export.tsv")
            .to_string_lossy()
            .to_string()
    };

    let queries_path = if let Some(idx) = args.iter().position(|a| a == "--queries") {
        args.get(idx + 1)
            .expect("--queries requires a path argument")
            .clone()
    } else {
        let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        manifest_dir
            .join("../../Resources/queries.tsv")
            .to_string_lossy()
            .to_string()
    };

    // Load queries from TSV
    let queries = load_queries(&queries_path);

    // Load corpus into memory
    println!("Loading corpus from {}...", tsv_path);
    let content = fs::read_to_string(&tsv_path).expect("Failed to read TSV file");
    let mut instruments: Vec<Instrument> = Vec::with_capacity(272_000);

    for (i, line) in content.lines().enumerate() {
        if i == 0 {
            continue;
        }
        let cols: Vec<&str> = line.split('\t').collect();
        if cols.len() >= 3 {
            instruments.push(Instrument {
                symbol: cols[0].to_string(),
                name: cols[1].to_string(),
                isin: cols[2].to_string(),
            });
        }
    }
    println!("Loaded {} instruments", instruments.len());

    // Pre-extract candidate arrays
    let symbol_candidates: Vec<&str> = instruments.iter().map(|i| i.symbol.as_str()).collect();
    let name_candidates: Vec<&str> = instruments.iter().map(|i| i.name.as_str()).collect();
    let isin_candidates: Vec<&str> = instruments.iter().map(|i| i.isin.as_str()).collect();

    println!("Running {} queries", queries.len());
    println!();

    let iterations: usize = if let Some(idx) = args.iter().position(|a| a == "--iterations") {
        args.get(idx + 1)
            .expect("--iterations requires a number")
            .parse()
            .expect("--iterations must be a positive integer")
    } else {
        5
    };

    // Warmup
    {
        let mut matcher = Matcher::new(Config::DEFAULT);
        let mut buf = Vec::new();
        for q in &queries {
            let candidates = if q.field == "symbol" {
                &symbol_candidates
            } else if q.field == "isin" {
                &isin_candidates
            } else {
                &name_candidates
            };
            let pattern =
                Pattern::new(&q.text, CaseMatching::Ignore, Normalization::Smart, AtomKind::Fuzzy);
            for candidate in candidates {
                buf.clear();
                let haystack = Utf32Str::new(candidate, &mut buf);
                let _ = pattern.score(haystack, &mut matcher);
            }
        }
        println!("Warmup complete");
    }

    // Per-query timing storage
    let query_count = queries.len();
    let mut query_timings_ms: Vec<Vec<f64>> = vec![Vec::new(); query_count];
    let mut query_match_counts: Vec<usize> = vec![0; query_count];
    let mut iteration_totals_ms: Vec<f64> = Vec::new();

    println!();
    println!(
        "=== Benchmark: nucleo scoring {} queries x {} candidates ===",
        query_count,
        instruments.len()
    );
    println!();

    let mut matcher = Matcher::new(Config::DEFAULT);
    for iter in 0..iterations {
        let mut buf = Vec::new();
        let iter_start = Instant::now();

        for (qi, q) in queries.iter().enumerate() {
            let candidates = if q.field == "symbol" {
                &symbol_candidates
            } else if q.field == "isin" {
                &isin_candidates
            } else {
                &name_candidates
            };
            let q_start = Instant::now();

            let pattern =
                Pattern::new(&q.text, CaseMatching::Ignore, Normalization::Smart, AtomKind::Fuzzy);
            let mut match_count: usize = 0;
            let mut heap: BinaryHeap<Reverse<(u32, usize)>> = BinaryHeap::with_capacity(TOP_K + 1);

            for (ci, candidate) in candidates.iter().enumerate() {
                buf.clear();
                let haystack = Utf32Str::new(candidate, &mut buf);
                if let Some(score) = pattern.score(haystack, &mut matcher) {
                    match_count += 1;
                    heap.push(Reverse((score, ci)));
                    if heap.len() > TOP_K {
                        heap.pop(); // remove the lowest score
                    }
                }
            }

            // Drain heap into a sorted Vec (highest score first)
            let mut top_results: Vec<(u32, usize)> = heap.into_iter().map(|Reverse(x)| x).collect();
            top_results.sort_by(|a, b| b.0.cmp(&a.0));

            let q_elapsed = q_start.elapsed();
            let q_ms = q_elapsed.as_secs_f64() * 1000.0;
            query_timings_ms[qi].push(q_ms);
            if iter == 0 {
                query_match_counts[qi] = match_count;
            }
        }

        let iter_elapsed = iter_start.elapsed();
        let iter_ms = iter_elapsed.as_secs_f64() * 1000.0;
        iteration_totals_ms.push(iter_ms);
        println!("Iteration {}: {:.1}ms total", iter + 1, iter_ms);
    }

    // Results
    println!();
    println!("=== Results ===");
    println!();

    let mut sorted_totals = iteration_totals_ms.clone();
    sorted_totals.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let median_total = sorted_totals[iterations / 2];
    let min_total = sorted_totals[0];
    let max_total = sorted_totals[iterations - 1];

    println!(
        "Total time for {} queries (min/median/max): {:.1}ms / {:.1}ms / {:.1}ms",
        query_count, min_total, median_total, max_total
    );

    let candidates_per_query = instruments.len() as f64;
    let total_candidates_scored = candidates_per_query * query_count as f64;
    let median_throughput = total_candidates_scored / (median_total / 1000.0);
    println!(
        "Throughput (median): {:.0}M candidates/sec",
        median_throughput / 1_000_000.0
    );
    println!(
        "Per-query average (median): {:.2}ms",
        median_total / query_count as f64
    );
    println!();

    // Per-category summary — use preferred order, skip missing
    let preferred_categories = [
        "exact_symbol",
        "exact_name",
        "exact_isin",
        "prefix",
        "typo",
        "substring",
        "multi_word",
        "symbol_spaces",
        "abbreviation",
    ];

    let category_set: std::collections::HashSet<&str> =
        queries.iter().map(|q| q.category.as_str()).collect();
    let categories: Vec<&str> = preferred_categories
        .iter()
        .filter(|c| category_set.contains(**c))
        .copied()
        .collect();

    println!(
        "{:<22} {:>8} {:>8} {:>8} {:>8}",
        "Category", "Queries", "Med(ms)", "Min(ms)", "Matches"
    );
    println!("{}", "-".repeat(60));

    for cat in &categories {
        let indices: Vec<usize> = queries
            .iter()
            .enumerate()
            .filter(|(_, q)| q.category == *cat)
            .map(|(i, _)| i)
            .collect();
        if indices.is_empty() {
            continue;
        }

        let total_median: f64 = indices
            .iter()
            .map(|&qi| {
                let mut sorted = query_timings_ms[qi].clone();
                sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
                sorted[iterations / 2]
            })
            .sum();
        let total_min: f64 = indices
            .iter()
            .map(|&qi| {
                query_timings_ms[qi]
                    .iter()
                    .cloned()
                    .reduce(f64::min)
                    .unwrap()
            })
            .sum();
        let total_matches: usize = indices.iter().map(|&qi| query_match_counts[qi]).sum();

        println!(
            "{:<22} {:>8} {:>8.2} {:>8.2} {:>8}",
            cat,
            indices.len(),
            total_median,
            total_min,
            total_matches
        );
    }

    println!();
    println!("=== Per-Query Detail (sorted by median time, descending) ===");
    println!();
    println!(
        "{:<32} {:<8} {:<16} {:>8} {:>8} {:>8}",
        "Query", "Field", "Category", "Med(ms)", "Min(ms)", "Matches"
    );
    println!("{}", "-".repeat(96));

    let mut sorted_indices: Vec<usize> = (0..query_count).collect();
    sorted_indices.sort_by(|&a, &b| {
        let mut sa = query_timings_ms[a].clone();
        sa.sort_by(|x, y| x.partial_cmp(y).unwrap());
        let mut sb = query_timings_ms[b].clone();
        sb.sort_by(|x, y| x.partial_cmp(y).unwrap());
        sb[iterations / 2]
            .partial_cmp(&sa[iterations / 2])
            .unwrap()
    });

    for qi in sorted_indices {
        let q = &queries[qi];
        let mut sorted = query_timings_ms[qi].clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let med = sorted[iterations / 2];
        let mn = sorted[0];
        let display_query = if q.text.len() > 30 {
            format!("{}...", &q.text[..27])
        } else {
            q.text.to_string()
        };
        println!(
            "{:<32} {:<8} {:<16} {:>8.2} {:>8.2} {:>8}",
            display_query, q.field, q.category, med, mn, query_match_counts[qi]
        );
    }
}
