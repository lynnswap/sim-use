// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import FBSimulatorControl
import Testing
@testable import iOSSimBackend

@Suite("Recorded touch primitive HID conversion")
struct RecordedTouchPrimitiveHIDTests {
    @Test("Single touch preserves phase, position, and acknowledgement uptime")
    func singleTouch() throws {
        let primitive = try #require(RecordedTouchPrimitive.acknowledged(
            .touch(direction: .down, x: 20, y: 30),
            dispatchUptimeNanoseconds: 42
        ))

        #expect(primitive.dispatchUptimeNanoseconds == 42)
        #expect(primitive.phase == .down)
        #expect(primitive.contacts == [
            .init(localID: 0, x: 20, y: 30),
        ])
    }

    @Test("Two-finger touch assigns stable local IDs within the publisher")
    func twoFingerTouch() throws {
        let primitive = try #require(RecordedTouchPrimitive.acknowledged(
            .twoFingerTouch(
                direction: .up,
                finger1: CGPoint(x: 10, y: 20),
                finger2: CGPoint(x: 30, y: 40)
            ),
            dispatchUptimeNanoseconds: 99
        ))

        #expect(primitive.phase == .up)
        #expect(primitive.contacts == [
            .init(localID: 1, x: 10, y: 20),
            .init(localID: 2, x: 30, y: 40),
        ])
    }

    @Test("Non-touch HID leaves do not enter the recording bridge")
    func ignoresNonTouch() {
        #expect(RecordedTouchPrimitive.acknowledged(
            .keyboard(direction: .down, keyCode: 4),
            dispatchUptimeNanoseconds: 1
        ) == nil)
    }
}
