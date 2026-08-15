import Darwin
import Foundation

// Entry point for the test runner. `swift run ClaudeIslandTests [filter]`.

// Several suites spawn the real hook client and write its stdin over a pipe. A
// client that exits before the write completes — which is exactly what the
// fire-and-forget paths are built to do — turns that write into SIGPIPE, and the
// default disposition kills the runner outright: no summary, output truncated
// mid-line, and a "failure" that names whichever test happened to be printing.
// That is what the intermittent full-suite failure was. The client itself already
// ignores SIGPIPE for the same reason; so must whatever spawns it.
signal(SIGPIPE, SIG_IGN)

// The socket suites hold hundreds of connections open at once and both ends live
// in this process, so a 300-connection stress test wants ~600 descriptors. The
// soft limit varies by configuration — small enough to matter on some, ~1M on
// this one — and running out would not fail the test that caused it: it makes
// some *later* `connect()` refuse, which reads as the server dropping a payload.
// Raised defensively so the suite measures the server rather than its own file
// table. Recorded honestly: this was *not* the cause of the drops it was first
// written to explain, which turned out to be the server's own read timeout.
var limits = rlimit()
if getrlimit(RLIMIT_NOFILE, &limits) == 0 {
    limits.rlim_cur = min(limits.rlim_max, 4096)
    _ = setrlimit(RLIMIT_NOFILE, &limits)
}

registerStateMachineTests()
registerSettingsTests()
registerTerminalAppsTests()
registerRedactorTests()
registerSessionStoreTests()
registerOwnerResolutionTests()
registerContextWindowTests()
registerStatuslineTests()
registerTranscriptTests()
registerSessionActivityTests()
registerTaskProgressTests()
registerHookInstallerTests()
registerPermissionDecisionTests()
registerSocketPipelineTests()
registerPipelineHealthTests()
registerReplayTests()

exit(await runAllTests())
