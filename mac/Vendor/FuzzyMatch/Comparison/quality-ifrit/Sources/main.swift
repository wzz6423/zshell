import Ifrit
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

// Read queries from stdin
// Fuse: lower score = better match, 0.0 = perfect, threshold 0.6 default
let fuse = Fuse(threshold: 0.6)

while let line = readLine() {
    let parts = line.split(separator: "\t", maxSplits: 1)
    guard parts.count == 2 else { continue }
    let query = String(parts[0])
    let field = String(parts[1])

    // Build candidate list for this field
    let candidates: [String] = instruments.map { field == "symbol" ? $0.symbol : field == "isin" ? $0.isin : $0.name }

    // searchSync returns [(index: Int, score: Double, ranges: [CountableClosedRange<Int>])]
    let results = fuse.searchSync(query, in: candidates)

    // Results are already sorted by score (lower = better)
    for (rank, r) in results.prefix(10).enumerated() {
        let inst = instruments[r.index]
        // Convert Fuse score (0=best, 1=worst) to comparable format
        let normalizedScore = 1.0 - r.diffScore
        print("\(query)\t\(field)\t\(rank+1)\t\(String(format: "%.4f", normalizedScore))\t\(inst.symbol)\t\(inst.name)")
    }
}
