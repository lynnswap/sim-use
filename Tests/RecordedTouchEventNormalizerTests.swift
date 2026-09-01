// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import FBSimulatorControl
import Testing
@testable import iOSSimBackend

@Suite("Recorded touch event normalizer")
@MainActor
struct RecordedTouchEventNormalizerTests {
    private let udid = "00000000-0000-0000-0000-000000000001"

    @Test("Tap becomes one began/ended contact without invented delay")
    func tap() throws {
        let normalizer = RecordedTouchEventNormalizer()
        let event = try #require(try normalizer.event(
            from: .tapAt(x: 30, y: 40),
            udid: udid,
            dispatchUptimeNanoseconds: 100
        ))

        #expect(event.dispatchUptimeNanoseconds == 100)
        #expect(event.samples.map(\.relativeNanoseconds) == [0, 0])
        #expect(event.samples.map { $0.contacts.map(\.contactID) } == [[0], [0]])
        #expect(event.samples.map { $0.contacts.map(\.phase) } == [[.began], [.ended]])
        #expect(event.samples[0].contacts[0].x == 30)
        #expect(event.samples[0].contacts[0].y == 40)
    }

    @Test("Nested composite preserves pre-delay and ends before post-delay")
    func nestedDelays() throws {
        let normalizer = RecordedTouchEventNormalizer()
        let hidEvent = FBSimulatorHIDEvent.composite([
            .delay(0.2),
            .composite([
                .touch(direction: .down, x: 10, y: 20),
                .delay(0.3),
                .touch(direction: .up, x: 50, y: 60),
            ]),
            .delay(0.4),
        ])

        let event = try #require(try normalizer.event(
            from: hidEvent,
            udid: udid,
            dispatchUptimeNanoseconds: 1_000
        ))

        #expect(event.samples.map(\.relativeNanoseconds) == [200_000_000, 500_000_000])
        #expect(event.samples.map { $0.contacts[0].phase } == [.began, .ended])
        #expect(event.samples.last?.contacts[0].x == 50)
        #expect(event.samples.last?.contacts[0].y == 60)
    }

    @Test("Repeated down becomes moved and split up closes the same contact ID")
    func repeatedDownAndSplitUp() throws {
        let normalizer = RecordedTouchEventNormalizer()
        let began = try #require(try normalizer.event(
            from: .touch(direction: .down, x: 10, y: 10),
            udid: udid,
            dispatchUptimeNanoseconds: 10
        ))
        let moved = try #require(try normalizer.event(
            from: .touch(direction: .down, x: 20, y: 20),
            udid: udid,
            dispatchUptimeNanoseconds: 20
        ))
        let ended = try #require(try normalizer.event(
            from: .touch(direction: .up, x: 20, y: 20),
            udid: udid,
            dispatchUptimeNanoseconds: 30
        ))

        #expect(began.eventID != moved.eventID)
        #expect(moved.eventID != ended.eventID)
        #expect(began.samples[0].contacts[0].phase == .began)
        #expect(moved.samples[0].contacts[0].phase == .moved)
        #expect(ended.samples[0].contacts[0].phase == .ended)
        #expect([began, moved, ended].allSatisfy { $0.samples[0].contacts[0].contactID == 0 })
    }

    @Test("Two-finger contacts use stable independent IDs")
    func twoFinger() throws {
        let normalizer = RecordedTouchEventNormalizer()
        let event = try #require(try normalizer.event(
            from: .composite([
                .twoFingerTouch(
                    direction: .down,
                    finger1: CGPoint(x: 10, y: 20),
                    finger2: CGPoint(x: 30, y: 40)
                ),
                .twoFingerTouch(
                    direction: .down,
                    finger1: CGPoint(x: 12, y: 22),
                    finger2: CGPoint(x: 32, y: 42)
                ),
                .twoFingerTouch(
                    direction: .up,
                    finger1: CGPoint(x: 12, y: 22),
                    finger2: CGPoint(x: 32, y: 42)
                ),
            ]),
            udid: udid,
            dispatchUptimeNanoseconds: 0
        ))

        #expect(event.samples.map { $0.contacts.map(\.contactID) } == [
            [1, 2], [1, 2], [1, 2],
        ])
        #expect(event.samples.map { $0.contacts.map(\.phase) } == [
            [.began, .began], [.moved, .moved], [.ended, .ended],
        ])
    }

    @Test("Non-touch HID produces no recording payload")
    func nonTouch() throws {
        let normalizer = RecordedTouchEventNormalizer()
        #expect(try normalizer.event(
            from: .shortKeyPress(40),
            udid: udid,
            dispatchUptimeNanoseconds: 0
        ) == nil)
    }

    @Test("Failed normalization does not commit a partial contact lifecycle")
    func invalidDelayRollsBack() throws {
        let normalizer = RecordedTouchEventNormalizer()
        #expect(throws: RecordedTouchNormalizationError.invalidDelay(.infinity)) {
            _ = try normalizer.event(
                from: .composite([
                    .touch(direction: .down, x: 10, y: 20),
                    .delay(.infinity),
                ]),
                udid: udid,
                dispatchUptimeNanoseconds: 0
            )
        }

        let event = try #require(try normalizer.event(
            from: .touch(direction: .down, x: 30, y: 40),
            udid: udid,
            dispatchUptimeNanoseconds: 1
        ))
        #expect(event.samples[0].contacts[0].phase == .began)
    }

    @Test("Final HID failure cancels held contacts at their last positions")
    func cancellation() throws {
        let normalizer = RecordedTouchEventNormalizer()
        _ = try normalizer.event(
            from: .twoFingerTouch(
                direction: .down,
                finger1: CGPoint(x: 10, y: 20),
                finger2: CGPoint(x: 30, y: 40)
            ),
            udid: udid,
            dispatchUptimeNanoseconds: 0
        )

        let cancellation = try #require(normalizer.cancellationEvent(
            udid: udid,
            dispatchUptimeNanoseconds: 10
        ))
        #expect(cancellation.samples[0].contacts.map(\.phase) == [.cancelled, .cancelled])
        #expect(cancellation.samples[0].contacts.map(\.contactID) == [1, 2])
        #expect(cancellation.samples[0].contacts.map(\.x) == [10, 30])
        #expect(cancellation.samples[0].contacts.map(\.y) == [20, 40])
        #expect(normalizer.cancellationEvent(udid: udid) == nil)
    }
}
