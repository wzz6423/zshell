use nucleo_matcher::pattern::{AtomKind, CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};
use std::env;
use std::fs;
use std::io::{self, BufRead};

struct Instrument {
    symbol: String,
    name: String,
    isin: String,
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let tsv_path = &args[1];

    let content = fs::read_to_string(tsv_path).expect("Failed to read TSV file");
    let mut instruments: Vec<Instrument> = Vec::new();

    for (i, line) in content.lines().enumerate() {
        if i == 0 {
            continue; // skip header
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

    let mut matcher = Matcher::new(Config::DEFAULT);
    let stdin = io::stdin();

    for line in stdin.lock().lines() {
        let line = line.expect("Failed to read line");
        let parts: Vec<&str> = line.splitn(2, '\t').collect();
        if parts.len() != 2 {
            continue;
        }
        let query = parts[0];
        let field = parts[1];

        let pattern = Pattern::new(query, CaseMatching::Ignore, Normalization::Smart, AtomKind::Fuzzy);

        let mut results: Vec<(u32, usize)> = Vec::new();
        let mut buf = Vec::new();

        for (idx, inst) in instruments.iter().enumerate() {
            let candidate = if field == "symbol" {
                &inst.symbol
            } else if field == "isin" {
                &inst.isin
            } else {
                &inst.name
            };

            buf.clear();
            let haystack = Utf32Str::new(candidate, &mut buf);
            if let Some(score) = pattern.score(haystack, &mut matcher) {
                results.push((score, idx));
            }
        }

        results.sort_by(|a, b| b.0.cmp(&a.0));

        for (rank, (score, idx)) in results.iter().take(10).enumerate() {
            let inst = &instruments[*idx];
            println!(
                "{}\t{}\t{}\t{}\t{}\t{}",
                query,
                field,
                rank + 1,
                score,
                inst.symbol,
                inst.name
            );
        }
    }
}
