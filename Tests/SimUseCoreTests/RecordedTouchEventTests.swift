// SPDX-License-Identifier: Apache-2.0
@testable import SimUseCore
import Foundation
import XCTest

final class RecordedTouchEventTests: XCTestCase {
    func testCodableRoundTripPreservesVersionIdentityAndOrderedSamples() throws {
        let event = RecordedTouchEvent(
            udid: "SIM-123",
            eventID: UUID(uuidString: "C68CC8B1-8752-408D-99B7-8AB8D478B849")!,
            dispatchUptimeNanoseconds: 42_000,
            samples: [
                .init(relativeNanoseconds: 0, contacts: [
                    .init(contactID: 1, phase: .began, x: 10.5, y: 20.25),
                    .init(contactID: 2, phase: .began, x: 30, y: 40),
                ]),
                .init(relativeNanoseconds: 75_000_000, contacts: [
                    .init(contactID: 1, phase: .moved, x: 11.5, y: 21.25),
                    .init(contactID: 2, phase: .cancelled, x: 30, y: 40),
                ]),
                .init(relativeNanoseconds: 100_000_000, contacts: [
                    .init(contactID: 1, phase: .ended, x: 12.5, y: 22.25),
                ]),
            ]
        )

        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(RecordedTouchEvent.self, from: encoded)

        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.version, RecordedTouchEvent.currentVersion)
        XCTAssertEqual(decoded.samples.map(\.relativeNanoseconds), [0, 75_000_000, 100_000_000])
        XCTAssertEqual(decoded.samples[0].contacts.map(\.contactID), [1, 2])
    }
}
