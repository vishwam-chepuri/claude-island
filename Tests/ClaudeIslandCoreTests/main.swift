import Foundation

// Entry point for the test runner. `swift run ClaudeIslandTests [filter]`.

registerStateMachineTests()
registerRedactorTests()
registerSessionStoreTests()
registerContextWindowTests()
registerStatuslineTests()
registerTranscriptTests()
registerTaskProgressTests()
registerHookInstallerTests()
registerSocketPipelineTests()
registerReplayTests()

exit(await runAllTests())
