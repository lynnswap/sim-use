// SPDX-License-Identifier: Apache-2.0
import Foundation

/// One acknowledged leaf touch sent by sim-use.
///
/// Contact identity is local to one publisher connection. Recorder-side code
/// must combine `publisherID` from `RecordedTouchInput` with `localID` before
/// storing visible contact state.
package struct RecordedTouchPrimitive: Codable, Equatable, Sendable {
    package enum Phase: String, Codable, Equatable, Sendable {
        case down
        case up
    }

    package struct Contact: Codable, Equatable, Sendable {
        package let localID: UInt8
        package let x: Double
        package let y: Double

        package init(localID: UInt8, x: Double, y: Double) {
            self.localID = localID
            self.x = x
            self.y = y
        }
    }

    package let dispatchUptimeNanoseconds: UInt64
    package let phase: Phase
    package let contacts: [Contact]

    package init(
        dispatchUptimeNanoseconds: UInt64,
        phase: Phase,
        contacts: [Contact]
    ) throws {
        guard Self.validContactCount.contains(contacts.count) else {
            throw RecordedTouchPrimitiveError.invalidContactCount(contacts.count)
        }
        self.dispatchUptimeNanoseconds = dispatchUptimeNanoseconds
        self.phase = phase
        self.contacts = contacts
    }

    static let validContactCount = 1...2
}

package enum RecordedTouchPrimitiveError: Error, Equatable, LocalizedError, Sendable {
    case invalidContactCount(Int)

    package var errorDescription: String? {
        switch self {
        case .invalidContactCount(let count):
            "A recorded touch primitive requires one or two contacts; got \(count)."
        }
    }
}

/// Immutable listener output. The renderer is the sole owner of the contact
/// lifecycle represented by these inputs.
package enum RecordedTouchInput: Equatable, Sendable {
    case update(publisherID: UUID, primitive: RecordedTouchPrimitive)
    case publisherClosed(publisherID: UUID, uptimeNanoseconds: UInt64)
}
