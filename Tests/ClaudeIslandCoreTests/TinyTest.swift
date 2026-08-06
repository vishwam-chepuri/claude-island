import Foundation

// A minimal test harness.
//
// Apple's Command Line Tools ship swift-testing's module and macro plugin but
// not `lib_TestingInterop.dylib`, so the test bundle compiles and then fails to
// dlopen; XCTest is Xcode-only. Since the project forbids third-party
// dependencies and must build from the CLI, this stands in. The call shapes
// deliberately mirror swift-testing (`expect`, `require`, `fail`) so the suites
// port back with a mechanical find-and-replace if Xcode ever lands.

struct Failure {
    let suite: String
    let test: String
    let message: String
    let file: String
    let line: Int
}

actor Recorder {
    static let shared = Recorder()
    private(set) var failures: [Failure] = []
    private var currentSuite = ""
    private var currentTest = ""

    func begin(suite: String, test: String) {
        currentSuite = suite
        currentTest = test
    }

    func record(_ message: String, file: String, line: Int) {
        failures.append(
            Failure(
                suite: currentSuite, test: currentTest, message: message,
                file: (file as NSString).lastPathComponent, line: line))
    }

    func failureCount() -> Int { failures.count }
    func all() -> [Failure] { failures }
}

/// Thrown by `require` so a test aborts rather than cascading.
struct RequirementFailed: Error {}

// Collected synchronously at registration time, run in order afterwards.
nonisolated(unsafe) var registry: [(suite: String, name: String, body: () async throws -> Void)] =
    []
nonisolated(unsafe) private var activeSuite = "General"

func suite(_ name: String, _ body: () -> Void) {
    let previous = activeSuite
    activeSuite = name
    body()
    activeSuite = previous
}

func test(_ name: String, _ body: @escaping () async throws -> Void) {
    registry.append((activeSuite, name, body))
}

func expect(
    _ condition: Bool, _ message: @autoclosure () -> String = "",
    file: String = #filePath, line: Int = #line
) async {
    guard !condition else { return }
    let detail = message()
    await Recorder.shared.record(
        detail.isEmpty ? "expectation failed" : detail, file: file, line: line)
}

func expectEqual<T: Equatable>(
    _ lhs: T, _ rhs: T, _ message: @autoclosure () -> String = "",
    file: String = #filePath, line: Int = #line
) async {
    guard lhs != rhs else { return }
    let extra = message()
    let base = "expected \(rhs), got \(lhs)"
    await Recorder.shared.record(extra.isEmpty ? base : "\(base) — \(extra)", file: file, line: line)
}

func require<T>(
    _ value: T?, _ message: @autoclosure () -> String = "",
    file: String = #filePath, line: Int = #line
) async throws -> T {
    guard let value else {
        let detail = message()
        await Recorder.shared.record(
            detail.isEmpty ? "required value was nil" : detail, file: file, line: line)
        throw RequirementFailed()
    }
    return value
}

func fail(_ message: String, file: String = #filePath, line: Int = #line) async {
    await Recorder.shared.record(message, file: file, line: line)
}

/// Asserts that `body` throws.
func expectThrows(
    _ message: @autoclosure () -> String = "throws expected",
    file: String = #filePath, line: Int = #line,
    _ body: () throws -> Void
) async {
    do {
        try body()
        await Recorder.shared.record(message(), file: file, line: line)
    } catch {
        // Expected.
    }
}

func runAllTests() async -> Int32 {
    let filter = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") }
    var run = 0
    var lastSuite = ""
    var failedTests = 0

    for entry in registry {
        if let filter, !entry.suite.localizedCaseInsensitiveContains(filter),
            !entry.name.localizedCaseInsensitiveContains(filter)
        {
            continue
        }
        if entry.suite != lastSuite {
            print("\n\(entry.suite)")
            lastSuite = entry.suite
        }

        let before = await Recorder.shared.failureCount()
        await Recorder.shared.begin(suite: entry.suite, test: entry.name)
        do {
            try await entry.body()
        } catch is RequirementFailed {
            // Already recorded.
        } catch {
            await Recorder.shared.record("threw \(error)", file: #filePath, line: #line)
        }
        let after = await Recorder.shared.failureCount()
        run += 1
        if after > before {
            failedTests += 1
            print("  ✗ \(entry.name)")
        } else {
            print("  ✓ \(entry.name)")
        }
    }

    let failures = await Recorder.shared.all()
    if failures.isEmpty {
        print("\n\(run) tests passed")
        return 0
    }

    print("\n\(failedTests) of \(run) tests failed:\n")
    for f in failures {
        print("  \(f.suite) › \(f.test)")
        print("    \(f.message)")
        print("    at \(f.file):\(f.line)")
    }
    return 1
}
