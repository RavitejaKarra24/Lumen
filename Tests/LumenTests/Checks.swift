import Foundation

// Minimal check harness: Lumen builds with Command Line Tools alone, where
// XCTest and Swift Testing are unavailable. Tests are sequential; a failing
// check prints its label and increments the failure count, and main.swift
// exits non-zero when anything failed.

// Sequential test execution makes unsynchronized counters safe here.
nonisolated(unsafe) var passedCount = 0
nonisolated(unsafe) var failedCount = 0

func check(_ condition: Bool, _ label: String, file: String = #fileID, line: UInt = #line) {
    if condition {
        passedCount += 1
    } else {
        failedCount += 1
        FileHandle.standardError.write(Data("FAIL: \(label) (\(file):\(line))\n".utf8))
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String, file: String = #fileID, line: UInt = #line) {
    check(actual == expected, "\(label) — expected \(expected), got \(actual)", file: file, line: line)
}

// Tests run on the main actor so helpers isolated to either side can be used
// freely; the work is lightweight and the store actor hops on its own. The
// body is @MainActor-isolated so callers from any context compose correctly.
@MainActor
func runTest(_ name: String, _ body: @MainActor () async throws -> Void) async {
    do {
        try await body()
        FileHandle.standardError.write(Data("ok: \(name)\n".utf8))
    } catch {
        failedCount += 1
        FileHandle.standardError.write(Data("FAIL: \(name) threw \(error)\n".utf8))
    }
}
