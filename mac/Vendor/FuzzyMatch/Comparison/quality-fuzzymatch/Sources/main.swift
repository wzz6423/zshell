import FuzzyMatch
import Foundation

struct Instrument {
    let symbol: String
    let name: String
    let isin: String
}

// Load TSV
let tsvPath = CommandLine.arguments[1]
let content = try! String(contentsOfFile: tsvPath, encoding: .utf8)
let lines = content.split(separator: "\n", omittingEmptySubsequences: false)

var instruments: [Instrument] = []
for (i, line) in lines.enumerated() {
    if i == 0 { continue } // skip header
    let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
    if cols.count >= 3 {
        instruments.append(Instrument(symbol: String(cols[0]), name: String(cols[1]), isin: String(cols[2])))
    }
}

// Parse --sw flag for Smith-Waterman mode
let useSmithWaterman = CommandLine.arguments.contains("--sw")
let config: MatchConfig = useSmithWaterman ? .smithWaterman : MatchConfig()
let matcher = FuzzyMatcher(config: config)
var buffer = matcher.makeBuffer()

while let line = readLine() {
    let parts = line.split(separator: "\t", maxSplits: 1)
    guard parts.count == 2 else { continue }
    let query = String(parts[0])
    let field = String(parts[1])

    let prepared = matcher.prepare(query)

    var results: [(score: Double, kind: String, symbol: String, name: String)] = []

    for inst in instruments {
        let candidate = field == "symbol" ? inst.symbol : field == "isin" ? inst.isin : inst.name
        if let match = matcher.score(candidate, against: prepared, buffer: &buffer) {
            results.append((match.score, "\(match.kind)", inst.symbol, inst.name))
        }
    }

    results.sort { $0.score > $1.score }

    for (rank, r) in results.prefix(10).enumerated() {
        print("\(query)\t\(field)\t\(rank+1)\t\(String(format: "%.4f", r.score))\t\(r.kind)\t\(r.symbol)\t\(r.name)")
    }
}
