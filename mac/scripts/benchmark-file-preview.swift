import Foundation

private let maxTextBytes = 5 << 20
private let arguments = CommandLine.arguments.dropFirst()
private let iterations = arguments.first.flatMap(Int.init) ?? 15
private let sizesMiB = arguments.dropFirst().compactMap(Int.init)
private let benchmarkSizes = sizesMiB.isEmpty ? [1, 5, 256] : sizesMiB

private enum ReadResult {
    case data(Data)
    case tooLarge
}

private func legacyRead(path: String) throws -> ReadResult {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return data.count <= maxTextBytes ? .data(data) : .tooLarge
}

private func boundedRead(path: String) throws -> ReadResult {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }

    let initialSize = try handle.seekToEnd()
    guard initialSize <= UInt64(maxTextBytes) else { return .tooLarge }
    try handle.seek(toOffset: 0)

    var data = Data()
    data.reserveCapacity(Int(initialSize))
    while data.count <= maxTextBytes {
        let remaining = maxTextBytes + 1 - data.count
        guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
            break
        }
        data.append(chunk)
    }
    guard data.count <= maxTextBytes,
          try handle.seekToEnd() <= UInt64(maxTextBytes) else {
        return .tooLarge
    }
    return .data(data)
}

private func byteCount(_ result: ReadResult) -> Int {
    switch result {
    case .data(let data): data.count
    case .tooLarge: -1
    }
}

private func percentile(_ samples: [Double], fraction: Double) -> Double {
    samples[min(samples.count - 1, Int(Double(samples.count) * fraction))]
}

private func measure(
    name: String,
    operation: () throws -> ReadResult
) throws {
    var samples: [Double] = []
    var sink = 0
    for _ in 0..<iterations {
        let start = ContinuousClock.now
        let count = try autoreleasepool { try byteCount(operation()) }
        let elapsed = start.duration(to: .now)
        samples.append(Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1.0e15)
        sink &+= count
    }
    samples.sort()
    let median = percentile(samples, fraction: 0.5)
    let p95 = percentile(samples, fraction: 0.95)
    print(String(
        format: "%@\tmedian=%.3fms\tp95=%.3fms\tsink=%d",
        name, median, p95, sink
    ))
}

private func createFixture(at url: URL, sizeMiB: Int) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    let chunk = Data(repeating: 0x78, count: 1 << 20)
    for _ in 0..<sizeMiB {
        try handle.write(contentsOf: chunk)
    }
}

guard iterations > 0, benchmarkSizes.allSatisfy({ $0 > 0 }) else {
    fatalError("Usage: swift benchmark-file-preview.swift [iterations] [sizeMiB ...]")
}

let environment = ProcessInfo.processInfo.environment
let baseDirectory = environment["CLAUDE_JOB_DIR"].map {
    URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("tmp")
} ?? FileManager.default.temporaryDirectory
let fixtureDirectory = baseDirectory.appendingPathComponent(
    "zshell-file-preview-benchmark-\(UUID().uuidString)",
    isDirectory: true
)
try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

for sizeMiB in benchmarkSizes {
    let fixture = fixtureDirectory.appendingPathComponent("fixture-\(sizeMiB)MiB.txt")
    try createFixture(at: fixture, sizeMiB: sizeMiB)
    for _ in 0..<3 {
        _ = try legacyRead(path: fixture.path)
        _ = try boundedRead(path: fixture.path)
    }
    print("contents=\(sizeMiB)MiB iterations=\(iterations)")
    try measure(name: "legacy-full-read") { try legacyRead(path: fixture.path) }
    try measure(name: "bounded-read") { try boundedRead(path: fixture.path) }
    try FileManager.default.removeItem(at: fixture)
}
