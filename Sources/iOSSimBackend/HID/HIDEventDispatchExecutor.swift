// SPDX-License-Identifier: Apache-2.0
import Foundation
import FBSimulatorControl

/// Owns the ordering boundary between a composite HID value and its acknowledged
/// leaf primitives. The caller publishes observable effects only from
/// `didSendPrimitive`, after `sendPrimitive` has returned successfully.
@MainActor
enum HIDEventDispatchExecutor {
    typealias PrimitiveSender = (FBSimulatorHIDEvent) async throws -> UInt64
    typealias DelaySleeper = (TimeInterval) async throws -> Void
    typealias Flush = () async throws -> Void
    typealias PrimitiveObserver = (FBSimulatorHIDEvent, UInt64) -> Void

    static func perform(
        _ event: FBSimulatorHIDEvent,
        sendPrimitive: PrimitiveSender,
        sleep: DelaySleeper,
        flush: Flush,
        didSendPrimitive: PrimitiveObserver
    ) async throws {
        try await dispatch(
            event,
            sendPrimitive: sendPrimitive,
            sleep: sleep,
            didSendPrimitive: didSendPrimitive
        )
        try await flush()
    }

    private static func dispatch(
        _ event: FBSimulatorHIDEvent,
        sendPrimitive: PrimitiveSender,
        sleep: DelaySleeper,
        didSendPrimitive: PrimitiveObserver
    ) async throws {
        switch event {
        case let .composite(events):
            for child in events {
                try await dispatch(
                    child,
                    sendPrimitive: sendPrimitive,
                    sleep: sleep,
                    didSendPrimitive: didSendPrimitive
                )
            }
        case let .delay(duration):
            try await sleep(max(0, duration))
        default:
            let dispatchUptimeNanoseconds = try await sendPrimitive(event)
            didSendPrimitive(event, dispatchUptimeNanoseconds)
        }
    }
}
