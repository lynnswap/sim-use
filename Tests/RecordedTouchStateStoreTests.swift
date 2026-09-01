// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import FBSimulatorControl
import Foundation
import Testing

@Suite("Recorded touch state store")
@MainActor
struct RecordedTouchStateStoreTests {
    private let udid = "SIM-BOOT-BOUND-TOUCH"
    private let marker = Date(timeIntervalSince1970: 1_782_991_697)
    private let simA = LaunchdSimIdentity(
        pid: 74691,
        startedAt: Date(timeIntervalSince1970: 1_784_773_778)
    )
    private let simB = LaunchdSimIdentity(
        pid: 79469,
        startedAt: Date(timeIntervalSince1970: 1_784_773_859)
    )

    @Test("Same-boot rebuild preserves the active contact")
    func sameBootPreservesState() throws {
        let store = RecordedTouchStateStore()
        let token = bootToken(simA)
        let first = store.normalizer(for: udid, bootToken: token)
        _ = try first.event(
            from: .touch(direction: .down, x: 10, y: 20),
            udid: udid,
            dispatchUptimeNanoseconds: 1
        )

        let rebound = store.normalizer(for: udid, bootToken: token)
        let moved = try #require(try rebound.event(
            from: .touch(direction: .down, x: 30, y: 40),
            udid: udid,
            dispatchUptimeNanoseconds: 2
        ))

        #expect(first === rebound)
        #expect(moved.samples[0].contacts[0].phase == .moved)
    }

    @Test("Cross-boot rebuild starts a fresh contact lifecycle")
    func changedBootResetsState() throws {
        let store = RecordedTouchStateStore()
        let first = store.normalizer(for: udid, bootToken: bootToken(simA))
        _ = try first.event(
            from: .touch(direction: .down, x: 10, y: 20),
            udid: udid,
            dispatchUptimeNanoseconds: 1
        )

        let rebound = store.normalizer(for: udid, bootToken: bootToken(simB))
        let began = try #require(try rebound.event(
            from: .touch(direction: .down, x: 30, y: 40),
            udid: udid,
            dispatchUptimeNanoseconds: 2
        ))

        #expect(first !== rebound)
        #expect(began.samples[0].contacts[0].phase == .began)
    }

    @Test("Explicit stale cleanup removes the boot-bound state")
    func explicitRemovalResetsState() throws {
        let store = RecordedTouchStateStore()
        let token = bootToken(simA)
        let first = store.normalizer(for: udid, bootToken: token)
        _ = try first.event(
            from: .touch(direction: .down, x: 10, y: 20),
            udid: udid,
            dispatchUptimeNanoseconds: 1
        )

        store.removeValue(for: udid)
        let rebound = store.normalizer(for: udid, bootToken: token)
        let began = try #require(try rebound.event(
            from: .touch(direction: .down, x: 30, y: 40),
            udid: udid,
            dispatchUptimeNanoseconds: 2
        ))

        #expect(first !== rebound)
        #expect(began.samples[0].contacts[0].phase == .began)
    }

    private func bootToken(_ identity: LaunchdSimIdentity) -> HIDBootToken {
        HIDBootToken(
            launchdSim: identity,
            markerModificationDate: marker
        )
    }
}
