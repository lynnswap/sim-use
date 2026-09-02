// SPDX-License-Identifier: Apache-2.0
import FBSimulatorControl

extension RecordedTouchPrimitive {
    static func acknowledged(
        _ event: FBSimulatorHIDEvent,
        dispatchUptimeNanoseconds: UInt64
    ) -> RecordedTouchPrimitive? {
        let phase: Phase
        let contacts: [Contact]

        switch event {
        case let .touch(direction, x, y):
            guard let resolvedPhase = Phase(direction) else { return nil }
            phase = resolvedPhase
            contacts = [.init(localID: 0, x: x, y: y)]

        case let .twoFingerTouch(direction, first, second):
            guard let resolvedPhase = Phase(direction) else { return nil }
            phase = resolvedPhase
            contacts = [
                .init(localID: 1, x: first.x, y: first.y),
                .init(localID: 2, x: second.x, y: second.y),
            ]

        default:
            return nil
        }

        return try? RecordedTouchPrimitive(
            dispatchUptimeNanoseconds: dispatchUptimeNanoseconds,
            phase: phase,
            contacts: contacts
        )
    }
}

private extension RecordedTouchPrimitive.Phase {
    init?(_ direction: FBSimulatorHIDDirection) {
        switch direction {
        case .down: self = .down
        case .up: self = .up
        @unknown default: return nil
        }
    }
}
