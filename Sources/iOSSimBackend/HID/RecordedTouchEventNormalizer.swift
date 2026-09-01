// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Dispatch
import Foundation
import FBSimulatorControl
import SimUseCore

/// Converts the public, ordered `FBSimulatorHIDEvent` value into the
/// platform-neutral contact timeline consumed by an active recording.
///
/// One normalizer is retained per simulator so split `touch --down` / `--up`
/// invocations preserve contact phase across daemon requests. Normalization
/// works on a local state copy and commits only after the whole event is
/// representable, so an invalid delay cannot leave the next event half-open.
@MainActor
final class RecordedTouchEventNormalizer {
    private struct State {
        var singleContactIsActive = false
        var singleContactPosition = CGPoint.zero
        var twoFingerContactsAreActive = false
        var firstFingerPosition = CGPoint.zero
        var secondFingerPosition = CGPoint.zero
    }

    private var state = State()

    func event(
        from hidEvent: FBSimulatorHIDEvent,
        udid: String,
        dispatchUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) throws -> RecordedTouchEvent? {
        var nextState = state
        var relativeNanoseconds: UInt64 = 0
        var samples: [RecordedTouchSample] = []

        try append(
            hidEvent,
            state: &nextState,
            relativeNanoseconds: &relativeNanoseconds,
            samples: &samples
        )

        guard !samples.isEmpty else { return nil }
        state = nextState
        return RecordedTouchEvent(
            udid: udid,
            dispatchUptimeNanoseconds: dispatchUptimeNanoseconds,
            samples: samples
        )
    }

    /// A final HID failure makes any held contact unknowable. Close the
    /// scheduled visual lifecycle instead of leaving an indicator active for
    /// the rest of the recording. This is called only after recovery/retry has
    /// failed; a successful transport retry keeps the original event intact.
    func cancellationEvent(
        udid: String,
        dispatchUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> RecordedTouchEvent? {
        var contacts: [RecordedTouchContact] = []
        if state.singleContactIsActive {
            contacts.append(.init(
                contactID: 0,
                phase: .cancelled,
                x: state.singleContactPosition.x,
                y: state.singleContactPosition.y
            ))
        }
        if state.twoFingerContactsAreActive {
            contacts.append(.init(
                contactID: 1,
                phase: .cancelled,
                x: state.firstFingerPosition.x,
                y: state.firstFingerPosition.y
            ))
            contacts.append(.init(
                contactID: 2,
                phase: .cancelled,
                x: state.secondFingerPosition.x,
                y: state.secondFingerPosition.y
            ))
        }
        state = State()
        guard !contacts.isEmpty else { return nil }
        return RecordedTouchEvent(
            udid: udid,
            dispatchUptimeNanoseconds: dispatchUptimeNanoseconds,
            samples: [.init(relativeNanoseconds: 0, contacts: contacts)]
        )
    }

    private func append(
        _ event: FBSimulatorHIDEvent,
        state: inout State,
        relativeNanoseconds: inout UInt64,
        samples: inout [RecordedTouchSample]
    ) throws {
        switch event {
        case let .touch(direction, x, y):
            state.singleContactPosition = CGPoint(x: x, y: y)
            let phase = Self.phase(
                for: direction,
                isActive: &state.singleContactIsActive
            )
            samples.append(.init(
                relativeNanoseconds: relativeNanoseconds,
                contacts: [.init(contactID: 0, phase: phase, x: x, y: y)]
            ))

        case let .twoFingerTouch(direction, finger1, finger2):
            state.firstFingerPosition = finger1
            state.secondFingerPosition = finger2
            let phase = Self.phase(
                for: direction,
                isActive: &state.twoFingerContactsAreActive
            )
            samples.append(.init(
                relativeNanoseconds: relativeNanoseconds,
                contacts: [
                    .init(
                        contactID: 1,
                        phase: phase,
                        x: finger1.x,
                        y: finger1.y
                    ),
                    .init(
                        contactID: 2,
                        phase: phase,
                        x: finger2.x,
                        y: finger2.y
                    ),
                ]
            ))

        case let .delay(duration):
            relativeNanoseconds = try Self.addingDelay(
                duration,
                to: relativeNanoseconds
            )

        case let .composite(events):
            for child in events {
                try append(
                    child,
                    state: &state,
                    relativeNanoseconds: &relativeNanoseconds,
                    samples: &samples
                )
            }

        case .button, .keyboard, .trackpad, .deviceOrientation, .shake,
             .toggleInCallStatusBar, .lockDevice:
            break
        }
    }

    private static func phase(
        for direction: FBSimulatorHIDDirection,
        isActive: inout Bool
    ) -> RecordedTouchPhase {
        switch direction {
        case .down:
            let phase: RecordedTouchPhase = isActive ? .moved : .began
            isActive = true
            return phase
        case .up:
            isActive = false
            return .ended
        @unknown default:
            isActive = false
            return .cancelled
        }
    }

    private static func addingDelay(
        _ duration: TimeInterval,
        to current: UInt64
    ) throws -> UInt64 {
        guard duration.isFinite else {
            throw RecordedTouchNormalizationError.invalidDelay(duration)
        }
        let nanoseconds = max(0, duration) * 1_000_000_000
        guard nanoseconds < Double(UInt64.max) else {
            throw RecordedTouchNormalizationError.delayOverflow(duration)
        }
        let roundedNanoseconds = UInt64(nanoseconds.rounded())
        guard roundedNanoseconds <= UInt64.max - current
        else {
            throw RecordedTouchNormalizationError.delayOverflow(duration)
        }
        return current + roundedNanoseconds
    }
}

enum RecordedTouchNormalizationError: Error, LocalizedError, Equatable {
    case invalidDelay(TimeInterval)
    case delayOverflow(TimeInterval)

    var errorDescription: String? {
        switch self {
        case let .invalidDelay(duration):
            "Cannot visualize a non-finite HID delay (\(duration))."
        case let .delayOverflow(duration):
            "Cannot represent the HID delay \(duration) seconds on the touch-indicator timeline."
        }
    }
}
