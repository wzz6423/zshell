#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <numeric>
#include <queue>
#include <set>
#include <string>
#include <vector>

#include <rapidfuzz/fuzz.hpp>

// ─── Data structures ───

struct Instrument {
    std::string symbol;
    std::string name;
    std::string isin;
};

struct Query {
    std::string text;
    std::string field;
    std::string category;
};

enum class Scorer { WRatio, PartialRatio };

// ─── Lowercase helper ───

static std::string to_lower(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (unsigned char c : s) out.push_back(static_cast<char>(std::tolower(c)));
    return out;
}

// ─── Load queries from TSV ───

static std::vector<Query> load_queries(const std::string& path) {
    std::vector<Query> queries;
    std::ifstream ifs(path);
    if (!ifs) {
        std::fprintf(stderr, "Error: cannot open queries file %s\n", path.c_str());
        std::exit(1);
    }
    std::string line;
    while (std::getline(ifs, line)) {
        if (line.empty()) continue;
        size_t t1 = line.find('\t');
        if (t1 == std::string::npos) continue;
        size_t t2 = line.find('\t', t1 + 1);
        if (t2 == std::string::npos) continue;
        queries.push_back({
            line.substr(0, t1),
            line.substr(t1 + 1, t2 - t1 - 1),
            line.substr(t2 + 1)
        });
    }
    return queries;
}

// ─── Score one query against all candidates (bounded min-heap, top-K) ───

static constexpr size_t kTopK = 100;

// Min-heap comparator: smallest score at the top so we can evict the worst.
struct MinScoreCmp {
    bool operator()(const std::pair<double, size_t>& a,
                    const std::pair<double, size_t>& b) const {
        return a.first > b.first; // greater-than → min-heap
    }
};

using TopKHeap = std::priority_queue<std::pair<double, size_t>,
                                     std::vector<std::pair<double, size_t>>,
                                     MinScoreCmp>;

template <typename ScorerT>
static void score_all(ScorerT& scorer, const std::vector<std::string>& candidates,
                      size_t& match_count, TopKHeap& top_heap) {
    for (size_t ci = 0; ci < candidates.size(); ++ci) {
        double score = scorer.similarity(candidates[ci], 0.0);
        if (score > 0.0) {
            ++match_count;
            top_heap.push({score, ci});
            if (top_heap.size() > kTopK) {
                top_heap.pop(); // evict lowest score
            }
        }
    }
}

// ─── Main ───

int main(int argc, char* argv[]) {
    // Parse arguments
    std::string tsv_path;
    std::string queries_path;
    Scorer scorer_type = Scorer::WRatio;

    int iterations = 3; // fewer than FM/nucleo — RapidFuzz (especially WRatio) is too slow for 5

    for (int i = 1; i < argc; ++i) {
        if (std::string(argv[i]) == "--tsv" && i + 1 < argc) {
            tsv_path = argv[++i];
        } else if (std::string(argv[i]) == "--queries" && i + 1 < argc) {
            queries_path = argv[++i];
        } else if (std::string(argv[i]) == "--scorer" && i + 1 < argc) {
            ++i;
            if (std::strcmp(argv[i], "partial_ratio") == 0) scorer_type = Scorer::PartialRatio;
            else scorer_type = Scorer::WRatio;
        } else if (std::string(argv[i]) == "--iterations" && i + 1 < argc) {
            iterations = std::atoi(argv[++i]);
        }
    }
    if (tsv_path.empty()) {
        tsv_path = "../../Resources/instruments-export.tsv";
    }
    if (queries_path.empty()) {
        queries_path = "../../Resources/queries.tsv";
    }

    const char* scorer_name = (scorer_type == Scorer::PartialRatio) ? "PartialRatio" : "WRatio";

    // Load queries from TSV
    auto queries = load_queries(queries_path);

    // Load corpus
    std::printf("Loading corpus from %s...", tsv_path.c_str());
    std::fflush(stdout);
    std::ifstream ifs(tsv_path);
    if (!ifs) {
        std::fprintf(stderr, " FAILED\nError: cannot open %s\n", tsv_path.c_str());
        return 1;
    }

    std::vector<Instrument> instruments;
    instruments.reserve(269000);
    std::string line;
    bool first = true;
    while (std::getline(ifs, line)) {
        if (first) { first = false; continue; }
        size_t t1 = line.find('\t');
        if (t1 == std::string::npos) continue;
        size_t t2 = line.find('\t', t1 + 1);
        if (t2 == std::string::npos) continue;
        instruments.push_back({
            line.substr(0, t1),
            line.substr(t1 + 1, t2 - t1 - 1),
            line.substr(t2 + 1)
        });
    }
    ifs.close();
    std::printf(" done\n");
    std::printf("Loaded %zu instruments\n", instruments.size());

    // Pre-extract candidate arrays (lowercased for case-insensitive matching)
    std::vector<std::string> symbol_lc, name_lc, isin_lc;
    symbol_lc.reserve(instruments.size());
    name_lc.reserve(instruments.size());
    isin_lc.reserve(instruments.size());
    for (auto& inst : instruments) {
        symbol_lc.push_back(to_lower(inst.symbol));
        name_lc.push_back(to_lower(inst.name));
        isin_lc.push_back(to_lower(inst.isin));
    }

    size_t query_count = queries.size();
    std::printf("Running %zu queries (scorer: %s)\n\n", query_count, scorer_name);


    // Warmup
    {
        for (auto& q : queries) {
            std::string q_lower = to_lower(q.text);
            auto& candidates = (q.field == "symbol") ? symbol_lc
                             : (q.field == "isin")   ? isin_lc
                             :                          name_lc;
            if (scorer_type == Scorer::PartialRatio) {
                rapidfuzz::fuzz::CachedPartialRatio<char> scorer(q_lower);
                for (auto& c : candidates) scorer.similarity(c, 0.0);
            } else {
                rapidfuzz::fuzz::CachedWRatio<char> scorer(q_lower);
                for (auto& c : candidates) scorer.similarity(c, 0.0);
            }
        }
        std::printf("Warmup complete\n");
    }

    // Per-query timing storage
    std::vector<std::vector<double>> query_timings_ms(query_count);
    std::vector<size_t> query_match_counts(query_count, 0);
    std::vector<double> iteration_totals_ms;

    std::printf("\n=== Benchmark: RapidFuzz(%s) scoring %zu queries x %zu candidates ===\n\n",
                scorer_name, query_count, instruments.size());

    for (int iter = 0; iter < iterations; ++iter) {
        auto iter_start = std::chrono::high_resolution_clock::now();

        for (size_t qi = 0; qi < query_count; ++qi) {
            auto& q = queries[qi];
            auto& candidates = (q.field == "symbol") ? symbol_lc
                             : (q.field == "isin")   ? isin_lc
                             :                          name_lc;

            auto q_start = std::chrono::high_resolution_clock::now();

            std::string q_lower = to_lower(q.text);
            size_t match_count = 0;
            TopKHeap top_heap;

            if (scorer_type == Scorer::PartialRatio) {
                rapidfuzz::fuzz::CachedPartialRatio<char> scorer(q_lower);
                score_all(scorer, candidates, match_count, top_heap);
            } else {
                rapidfuzz::fuzz::CachedWRatio<char> scorer(q_lower);
                score_all(scorer, candidates, match_count, top_heap);
            }

            auto q_end = std::chrono::high_resolution_clock::now();
            double q_ms = std::chrono::duration<double, std::milli>(q_end - q_start).count();
            query_timings_ms[qi].push_back(q_ms);
            if (iter == 0) {
                query_match_counts[qi] = match_count;
            }
        }

        auto iter_end = std::chrono::high_resolution_clock::now();
        double iter_ms = std::chrono::duration<double, std::milli>(iter_end - iter_start).count();
        iteration_totals_ms.push_back(iter_ms);
        std::printf("Iteration %d: %.1fms total\n", iter + 1, iter_ms);
    }

    // Results
    std::printf("\n=== Results ===\n\n");

    auto sorted_totals = iteration_totals_ms;
    std::sort(sorted_totals.begin(), sorted_totals.end());
    double median_total = sorted_totals[iterations / 2];
    double min_total = sorted_totals.front();
    double max_total = sorted_totals.back();

    std::printf("Total time for %zu queries (min/median/max): %.1fms / %.1fms / %.1fms\n",
                query_count, min_total, median_total, max_total);

    double candidates_per_query = static_cast<double>(instruments.size());
    double total_scored = candidates_per_query * static_cast<double>(query_count);
    double median_throughput = total_scored / (median_total / 1000.0);
    std::printf("Throughput (median): %.0fM candidates/sec\n", median_throughput / 1e6);
    std::printf("Per-query average (median): %.2fms\n\n", median_total / static_cast<double>(query_count));

    // Per-category summary — use preferred order, skip missing
    const char* preferred_categories[] = {
        "exact_symbol", "exact_name", "exact_isin", "prefix",
        "typo", "substring", "multi_word", "symbol_spaces", "abbreviation"
    };

    std::set<std::string> category_set;
    for (auto& q : queries) category_set.insert(q.category);

    std::printf("%-22s %8s %8s %8s %8s\n", "Category", "Queries", "Med(ms)", "Min(ms)", "Matches");
    for (int i = 0; i < 60; ++i) std::putchar('-');
    std::putchar('\n');

    for (auto cat : preferred_categories) {
        if (category_set.find(cat) == category_set.end()) continue;

        std::vector<size_t> indices;
        for (size_t i = 0; i < query_count; ++i) {
            if (queries[i].category == cat) indices.push_back(i);
        }
        if (indices.empty()) continue;

        double total_median = 0, total_min = 0;
        size_t total_matches = 0;
        for (auto qi : indices) {
            auto sorted = query_timings_ms[qi];
            std::sort(sorted.begin(), sorted.end());
            total_median += sorted[iterations / 2];
            total_min += sorted.front();
            total_matches += query_match_counts[qi];
        }

        std::printf("%-22s %8zu %8.2f %8.2f %8zu\n",
                    cat, indices.size(), total_median, total_min, total_matches);
    }

    // Per-query detail
    std::printf("\n=== Per-Query Detail (sorted by median time, descending) ===\n\n");
    std::printf("%-32s %-8s %-16s %8s %8s %8s\n",
                "Query", "Field", "Category", "Med(ms)", "Min(ms)", "Matches");
    for (int i = 0; i < 96; ++i) std::putchar('-');
    std::putchar('\n');

    std::vector<size_t> sorted_indices(query_count);
    std::iota(sorted_indices.begin(), sorted_indices.end(), 0);
    std::sort(sorted_indices.begin(), sorted_indices.end(), [&](size_t a, size_t b) {
        auto sa = query_timings_ms[a]; std::sort(sa.begin(), sa.end());
        auto sb = query_timings_ms[b]; std::sort(sb.begin(), sb.end());
        return sb[iterations / 2] < sa[iterations / 2];
    });

    for (auto qi : sorted_indices) {
        auto& q = queries[qi];
        auto sorted = query_timings_ms[qi];
        std::sort(sorted.begin(), sorted.end());
        double med = sorted[iterations / 2];
        double mn = sorted.front();
        std::string display = q.text;
        if (display.size() > 30) display = display.substr(0, 27) + "...";
        std::printf("%-32s %-8s %-16s %8.2f %8.2f %8zu\n",
                    display.c_str(), q.field.c_str(), q.category.c_str(), med, mn, query_match_counts[qi]);
    }

    return 0;
}
