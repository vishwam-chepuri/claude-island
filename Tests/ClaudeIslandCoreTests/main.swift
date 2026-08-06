import Foundation

// Entry point for the test runner. `swift run ClaudeIslandTests [filter]`.

registerStateMachineTests()
registerRedactorTests()
registerSessionStoreTests()
registerTranscriptTests()
registerTaskProgressTests()
registerHookInstallerTests()
registerSocketPipelineTests()
registerReplayTests()

exit(await runAllTests())
