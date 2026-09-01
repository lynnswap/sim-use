// SPDX-License-Identifier: Apache-2.0
import Foundation

/// One logical touch batch scheduled by sim-use for a specific device.
///
/// The event UUID identifies the batch for diagnostics and de-duplication.
/// Contact lifetime is identified separately by `RecordedTouchContact.contactID`:
/// split down/up commands may have different event UUIDs while continuing the
/// same contact.
package struct RecordedTouchEvent: Codable, Equatable, Sendable {
    package static let currentVersion = 1

    package let version: Int
    package let udid: String
    package let eventID: UUID
    package let dispatchUptimeNanoseconds: UInt64
    package let samples: [RecordedTouchSample]

    package init(
        version: Int = Self.currentVersion,
        udid: String,
        eventID: UUID = UUID(),
        dispatchUptimeNanoseconds: UInt64,
        samples: [RecordedTouchSample]
    ) {
        self.version = version
        self.udid = udid
        self.eventID = eventID
        self.dispatchUptimeNanoseconds = dispatchUptimeNanoseconds
        self.samples = samples
    }
}

/// Contact changes that occur at one offset from the batch dispatch time.
/// Samples remain in wire order; offsets must be monotonically nondecreasing.
package struct RecordedTouchSample: Codable, Equatable, Sendable {
    package let relativeNanoseconds: UInt64
    package let contacts: [RecordedTouchContact]

    package init(relativeNanoseconds: UInt64, contacts: [RecordedTouchContact]) {
        self.relativeNanoseconds = relativeNanoseconds
        self.contacts = contacts
    }
}

/// A single contact update in device/HID coordinates.
///
/// `contactID` is stable for the lifetime of a contact within one UDID's event
/// channel. It is intentionally independent of an event UUID so separately
/// issued down/up commands can describe one continuous contact.
package struct RecordedTouchContact: Codable, Equatable, Sendable {
    package let contactID: UInt32
    package let phase: RecordedTouchPhase
    package let x: Double
    package let y: Double

    package init(contactID: UInt32, phase: RecordedTouchPhase, x: Double, y: Double) {
        self.contactID = contactID
        self.phase = phase
        self.x = x
        self.y = y
    }
}

package enum RecordedTouchPhase: String, Codable, Equatable, Sendable {
    case began
    case moved
    case ended
    case cancelled
}
