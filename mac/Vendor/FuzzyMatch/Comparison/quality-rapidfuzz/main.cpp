#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include <rapidfuzz/fuzz.hpp>

enum class Scorer { WRatio, PartialRatio };

struct Instrument {
    std::string symbol;
    std::string name;
    std::string isin;
};

static std::string to_lower(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (unsigned char c : s) out.push_back(static_cast<char>(std::tolower(c)));
    return out;
}

template <typename ScorerT>
static void score_query(ScorerT& scorer, const std::vector<std::string>& candidates,
                        const std::vector<Instrument>& instruments,
                        const std::string& query, const std::string& field) {
    std::vector<std::pair<double, size_t>> results;
    for (size_t i = 0; i < candidates.size(); ++i) {
        double score = scorer.similarity(candidates[i], 0.0);
        if (score > 0.0) {
            results.push_back({score, i});
        }
    }

    std::partial_sort(results.begin(),
                      results.begin() + std::min<size_t>(10, results.size()),
                      results.end(),
                      [](auto& a, auto& b) { return a.first > b.first; });

    size_t limit = std::min<size_t>(10, results.size());
    for (size_t rank = 0; rank < limit; ++rank) {
        auto& [score, idx] = results[rank];
        auto& inst = instruments[idx];
        std::printf("%s\t%s\t%zu\t%.4f\t%s\t%s\n",
                    query.c_str(), field.c_str(), rank + 1, score,
                    inst.symbol.c_str(), inst.name.c_str());
    }
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::fprintf(stderr, "Usage: %s <tsv-path> [--scorer wratio|partial_ratio]\n", argv[0]);
        return 1;
    }

    // Parse arguments
    std::string tsv_path = argv[1];
    Scorer scorer_type = Scorer::WRatio;
    for (int i = 2; i < argc; ++i) {
        if (std::strcmp(argv[i], "--scorer") == 0 && i + 1 < argc) {
            ++i;
            if (std::strcmp(argv[i], "partial_ratio") == 0) scorer_type = Scorer::PartialRatio;
        }
    }

    // Load corpus
    std::ifstream ifs(tsv_path);
    if (!ifs) {
        std::fprintf(stderr, "Error: cannot open %s\n", tsv_path.c_str());
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

    // Pre-lowercase all candidates
    std::vector<std::string> symbol_lc, name_lc, isin_lc;
    symbol_lc.reserve(instruments.size());
    name_lc.reserve(instruments.size());
    isin_lc.reserve(instruments.size());
    for (auto& inst : instruments) {
        symbol_lc.push_back(to_lower(inst.symbol));
        name_lc.push_back(to_lower(inst.name));
        isin_lc.push_back(to_lower(inst.isin));
    }

    // Read queries from stdin: "query\tfield"
    std::string input_line;
    while (std::getline(std::cin, input_line)) {
        if (input_line.empty()) continue;
        size_t tab = input_line.find('\t');
        if (tab == std::string::npos) continue;
        std::string query = input_line.substr(0, tab);
        std::string field = input_line.substr(tab + 1);

        std::string q_lower = to_lower(query);

        auto& candidates = (field == "symbol") ? symbol_lc
                         : (field == "isin")   ? isin_lc
                         :                       name_lc;

        if (scorer_type == Scorer::PartialRatio) {
            rapidfuzz::fuzz::CachedPartialRatio<char> scorer(q_lower);
            score_query(scorer, candidates, instruments, query, field);
        } else {
            rapidfuzz::fuzz::CachedWRatio<char> scorer(q_lower);
            score_query(scorer, candidates, instruments, query, field);
        }
    }

    return 0;
}
