// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import CoreGraphics
import FBSimulatorControl
import Testing

@Suite("HID event dispatch executor")
@MainActor
struct HIDEventDispatchExecutorTests {
    private struct SendFailure: Error {}
    private struct TimeoutMarker: Error {}

    @Test("Nested composites publish acknowledged primitives in live order and flush once")
    func nestedCompositeOrder() async throws {
        let down = FBSimulatorHIDEvent.touch(direction: .down, x: 10, y: 20)
        let up = FBSimulatorHIDEvent.touch(direction: .up, x: 30, y: 40)
        var actions: [String] = []
        var timestamps: [UInt64] = [100, 200]

        try await HIDEventDispatchExecutor.perform(
            .composite([down, .delay(0.25), .composite([up])]),
            sendPrimitive: { primitive in
                actions.append("send:\(primitive)")
                return timestamps.removeFirst()
            },
            sleep: { duration in actions.append("delay:\(duration)") },
            flush: { actions.append("flush") },
            didSendPrimitive: { primitive, timestamp in
                actions.append("publish:\(timestamp):\(primitive)")
            }
        )

        #expect(actions == [
            "send:\(down)",
            "publish:100:\(down)",
            "delay:0.25",
            "send:\(up)",
            "publish:200:\(up)",
            "flush",
        ])
    }

    @Test("A failed primitive is not published and prevents flush")
    func failedPrimitiveIsNotPublished() async {
        var published = false
        var flushed = false

        await #expect(throws: SendFailure.self) {
            try await HIDEventDispatchExecutor.perform(
                .touch(direction: .down, x: 10, y: 20),
                sendPrimitive: { _ in throw SendFailure() },
                sleep: { _ in },
                flush: { flushed = true },
                didSendPrimitive: { _, _ in published = true }
            )
        }

        #expect(!published)
        #expect(!flushed)
    }

    @Test("A later failure preserves only the primitives already acknowledged")
    func partialSuccessIsNotReplayedByExecutor() async {
        let down = FBSimulatorHIDEvent.touch(direction: .down, x: 10, y: 20)
        let up = FBSimulatorHIDEvent.touch(direction: .up, x: 10, y: 20)
        var sendCount = 0
        var published: [FBSimulatorHIDEvent] = []

        await #expect(throws: SendFailure.self) {
            try await HIDEventDispatchExecutor.perform(
                .composite([down, up]),
                sendPrimitive: { _ in
                    defer { sendCount += 1 }
                    if sendCount == 1 { throw SendFailure() }
                    return 100
                },
                sleep: { _ in },
                flush: {},
                didSendPrimitive: { primitive, _ in published.append(primitive) }
            )
        }

        #expect(published == [down])
    }

    @Test("A timed-out send cannot publish when its abandoned task completes later", .timeLimit(.minutes(1)))
    func timedOutSendCannotPublishLate() async {
        let gate = LateCompletionGate()
        var published = false

        await #expect(throws: TimeoutMarker.self) {
            try await HIDEventDispatchExecutor.perform(
                .touch(direction: .down, x: 10, y: 20),
                sendPrimitive: { _ in
                    try await HIDSendDeadline.run(milliseconds: 20) {
                        let timestamp = await gate.wait()
                        await gate.markFinished()
                        return timestamp
                    } onTimeout: {
                        TimeoutMarker()
                    }
                },
                sleep: { _ in },
                flush: {},
                didSendPrimitive: { _, _ in published = true }
            )
        }

        await gate.release(returning: 42)
        await gate.waitUntilFinished()
        #expect(!published)
    }

    private actor LateCompletionGate {
        private var continuation: CheckedContinuation<UInt64, Never>?
        private var releasedValue: UInt64?
        private var finished = false
        private var finishWaiters: [CheckedContinuation<Void, Never>] = []

        func wait() async -> UInt64 {
            if let releasedValue { return releasedValue }
            return await withCheckedContinuation { continuation = $0 }
        }

        func release(returning value: UInt64) {
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: value)
            } else {
                releasedValue = value
            }
        }

        func markFinished() {
            finished = true
            for waiter in finishWaiters { waiter.resume() }
            finishWaiters.removeAll()
        }

        func waitUntilFinished() async {
            if finished { return }
            await withCheckedContinuation { finishWaiters.append($0) }
        }
    }
}
