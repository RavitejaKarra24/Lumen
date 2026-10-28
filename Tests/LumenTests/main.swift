import Foundation
@testable import LumenKit

// Entry point for the Lumen test harness. Each group prints its failures and
// the process exits non-zero when any check failed, which is what CI keys on.

await runDeepWorkTests()
await runClassifierTests()
await runDayClippingTests()
await runStoreTests()
await runIdleBackdatingTests()
await runCaptureTests()
await runIntelligenceModeTests()
await runNoteDraftTests()
await runLoginItemTests()

print("Lumen test harness: \(passedCount) passed, \(failedCount) failed.")
exit(failedCount == 0 ? 0 : 1)
