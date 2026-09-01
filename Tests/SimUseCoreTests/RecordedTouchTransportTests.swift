// SPDX-License-Identifier: Apache-2.0
@testable import SimUseCore
import Darwin
import Foundation
import XCTest

final class RecordedTouchTransportTests: XCTestCase {
    private let deadPID: pid_t = 9_999_997

    func testListenerPublisherRoundTripUsesSecurePerUDIDPaths() throws {
        let base = makeBaseDirectoryURL()
        defer { removeTemporaryDirectory(base) }
        let event = makeEvent(udid: "SIM-ROUNDTRIP")
        let received = expectation(description: "listener received event")

        let listener = try RecordedTouchEventListener(
            udid: event.udid,
            baseDirectory: base,
            onEvent: { delivered in
                XCTAssertEqual(delivered, event)
                received.fulfill()
            },
            onDiagnostic: { diagnostic in
                XCTFail("Unexpected diagnostic: \(diagnostic)")
            }
        )
        defer { listener.close() }

        XCTAssertEqual(mode(of: base) & 0o777, 0o700)
        XCTAssertEqual(mode(of: listener.paths.channelDirectory) & 0o777, 0o700)
        XCTAssertEqual(mode(of: listener.paths.socketURL) & 0o777, 0o600)
        XCTAssertEqual(mode(of: listener.paths.pidfileURL) & 0o777, 0o600)

        let result = RecordedTouchEventPublisher(
            udid: event.udid,
            baseDirectory: base
        ).publish(event)
        XCTAssertEqual(result, .delivered)
        wait(for: [received], timeout: 2)
    }

    func testListenerOwnershipIsOutsideDaemonDiscoveryNamespace() throws {
        let base = makeBaseDirectoryURL()
        defer { removeTemporaryDirectory(base) }
        let listener = try RecordedTouchEventListener(
            udid: "SIM-NOT-A-DAEMON",
            baseDirectory: base,
            onEvent: { _ in }
        )
        defer { listener.close() }

        XCTAssertTrue(try DaemonPaths.enumerateLiveDaemons(baseDirectory: base).isEmpty)
    }

    func testFailedTerminalDatagramIsRecoveredAfterDeliveredDown() throws {
        let base = makeBaseDirectoryURL()
        defer { removeTemporaryDirectory(base) }
        let udid = "SIM-TERMINAL-RECOVERY"
        let down = makeSingleContactEvent(
            udid: udid,
            phase: .began,
            dispatchUptimeNanoseconds: 100
        )
        let up = makeSingleContactEvent(
            udid: udid,
            phase: .ended,
            dispatchUptimeNanoseconds: 200
        )
        let received = expectation(description: "down and recovered up delivered")
        received.expectedFulfillmentCount = 2
        let receivedEvents = LockedBox<[RecordedTouchEvent]>([])

        let listener = try RecordedTouchEventListener(
            udid: udid,
            baseDirectory: base,
            onEvent: { event in
                receivedEvents.withValue { $0.append(event) }
                received.fulfill()
            },
            onDiagnostic: { diagnostic in
                XCTFail("Unexpected diagnostic: \(diagnostic)")
            }
        )
        defer { listener.close() }

        XCTAssertEqual(
            RecordedTouchEventPublisher(udid: udid, baseDirectory: base)
                .publish(down),
            .delivered
        )

        let sendCount = LockedBox(0)
        let failingSender = RecordedTouchDatagramSender { _, _, _ in
            sendCount.withValue { $0 += 1 }
            return .failed(errorNumber: EAGAIN)
        }
        let terminalResult = RecordedTouchEventPublisher(
            udid: udid,
            baseDirectory: base,
            datagramSender: failingSender
        ).publish(up)
        guard case .failed(let diagnostic) = terminalResult else {
            return XCTFail("Expected injected terminal delivery failure")
        }
        XCTAssertEqual(diagnostic.kind, .deliveryFailed)
        XCTAssertTrue(diagnostic.message.contains("terminal recovery queued"))

        wait(for: [received], timeout: 2)
        XCTAssertEqual(sendCount.value, 1)
        XCTAssertEqual(
            receivedEvents.value.flatMap(\.samples).flatMap(\.contacts).map(\.phase),
            [.began, .ended]
        )
    }

    func testLargeGestureTimelineIsChunkedWithoutDroppingSamples() throws {
        let base = makeBaseDirectoryURL()
        defer { removeTemporaryDirectory(base) }
        let udid = "SIM-LARGE-GESTURE"
        var samples: [RecordedTouchSample] = []
        for index in 0..<120 {
            let phase: RecordedTouchPhase
            if index == 0 {
                phase = .began
            } else if index == 119 {
                phase = .ended
            } else {
                phase = .moved
            }
            samples.append(RecordedTouchSample(
                relativeNanoseconds: UInt64(index) * 10_000_000,
                contacts: [
                    .init(
                        contactID: 0,
                        phase: phase,
                        x: Double(index),
                        y: Double(index * 2)
                    ),
                ]
            ))
        }
        let event = RecordedTouchEvent(
            udid: udid,
            eventID: UUID(),
            dispatchUptimeNanoseconds: 100,
            samples: samples
        )
        let expectedSamples = samples
        XCTAssertGreaterThan(try JSONEncoder().encode(event).count, 2_048)

        let receivedEvent = LockedBox<RecordedTouchEvent?>(nil)
        let receivedCompleteEvent = expectation(description: "listener received one complete event")
        let listener = try RecordedTouchEventListener(
            udid: udid,
            baseDirectory: base,
            onEvent: { received in
                receivedEvent.withValue { $0 = received }
                receivedCompleteEvent.fulfill()
            },
            onDiagnostic: { diagnostic in
                XCTFail("Unexpected diagnostic: \(diagnostic)")
            }
        )
        defer { listener.close() }

        XCTAssertEqual(
            RecordedTouchEventPublisher(udid: udid, baseDirectory: base).publish(event),
            .delivered
        )
        wait(for: [receivedCompleteEvent], timeout: 2)
        XCTAssertEqual(receivedEvent.value, event)
        XCTAssertEqual(receivedEvent.value?.samples, expectedSamples)
    }

    func testIncompleteChunkIsNeverPublishedAndDoesNotBlockAnotherEvent() throws {
        let base = makeBaseDirectoryURL()
        defer { removeTemporaryDirectory(base) }
        let udid = "SIM-PARTIAL"
        let partial = makeEvent(udid: udid)
        let unrelated = makeEvent(udid: udid)
        let unrelatedDelivered = expectation(description: "complete unrelated event delivered")

        let listener = try RecordedTouchEventListener(
            udid: udid,
            baseDirectory: base,
            onEvent: { event in
                if event.eventID == partial.eventID {
                    XCTFail("An incomplete event must never reach the listener callback")
                }
                if event.eventID == unrelated.eventID {
                    unrelatedDelivered.fulfill()
                }
            }
        )
        defer { listener.close() }

        let firstChunk = RecordedTouchEventDatagram(
            event: copy(partial, samples: [partial.samples[0]]),
            chunkIndex: 0,
            chunkCount: 2
        )
        try sendRawDatagram(JSONEncoder().encode(firstChunk), to: listener.paths.socketURL.path)
        XCTAssertEqual(
            RecordedTouchEventPublisher(udid: udid, baseDirectory: base).publish(unrelated),
            .delivered
        )

        wait(for: [unrelatedDelivered], timeout: 2)
    }

    func testReassemblerAcceptsOutOfOrderAndDuplicateChunksExactlyOnce() throws {
        let udid = "SIM-REASSEMBLY"
        let event = makeEvent(udid: udid)
        let first = RecordedTouchEventDatagram(
            event: copy(event, samples: [event.samples[0]]),
            chunkIndex: 0,
            chunkCount: 2
        )
        let second = RecordedTouchEventDatagram(
            event: copy(event, samples: [event.samples[1]]),
            chunkIndex: 1,
            chunkCount: 2
        )
        var reassembler = RecordedTouchEventReassembler()

        XCTAssertNil(reassembler.accept(
            second,
            encodedBytes: try JSONEncoder().encode(second).count,
            expectedUDID: udid,
            nowNanoseconds: 10
        ).event)
        XCTAssertNil(reassembler.accept(
            second,
            encodedBytes: try JSONEncoder().encode(second).count,
            expectedUDID: udid,
            nowNanoseconds: 11
        ).event)
        XCTAssertEqual(reassembler.accept(
            first,
            encodedBytes: try JSONEncoder().encode(first).count,
            expectedUDID: udid,
            nowNanoseconds: 12
        ).event, event)
        XCTAssertNil(reassembler.accept(
            first,
            encodedBytes: try JSONEncoder().encode(first).count,
            expectedUDID: udid,
            nowNanoseconds: 13
        ).event)
    }

    func testConflictingChunkDiscardsAndTombstonesWholeEvent() throws {
        let udid = "SIM-CONFLICT"
        let event = makeEvent(udid: udid)
        let first = RecordedTouchEventDatagram(
            event: copy(event, samples: [event.samples[0]]),
            chunkIndex: 0,
            chunkCount: 2
        )
        let conflicting = RecordedTouchEventDatagram(
            event: copy(event, samples: [event.samples[1]]),
            chunkIndex: 0,
            chunkCount: 2
        )
        let second = RecordedTouchEventDatagram(
            event: copy(event, samples: [event.samples[1]]),
            chunkIndex: 1,
            chunkCount: 2
        )
        var reassembler = RecordedTouchEventReassembler()

        _ = reassembler.accept(first, encodedBytes: 100, expectedUDID: udid, nowNanoseconds: 10)
        let rejected = reassembler.accept(
            conflicting,
            encodedBytes: 100,
            expectedUDID: udid,
            nowNanoseconds: 11
        )
        XCTAssertEqual(rejected.diagnostics.last?.kind, .invalidChunkMetadata)
        XCTAssertNil(rejected.event)
        XCTAssertNil(reassembler.accept(
            second,
            encodedBytes: 100,
            expectedUDID: udid,
            nowNanoseconds: 12
        ).event)
    }

    func testTerminalRecoverySupersedesPartialChunksForTheSameEvent() {
        let udid = "SIM-PARTIAL-RECOVERY"
        let event = makeEvent(udid: udid)
        let first = RecordedTouchEventDatagram(
            event: copy(event, samples: [event.samples[0]]),
            chunkIndex: 0,
            chunkCount: 2
        )
        let second = RecordedTouchEventDatagram(
            event: copy(event, samples: [event.samples[1]]),
            chunkIndex: 1,
            chunkCount: 2
        )
        let recovery = copy(event, samples: [event.samples[1]])
        var reassembler = RecordedTouchEventReassembler()

        XCTAssertNil(reassembler.accept(
            first,
            encodedBytes: 100,
            expectedUDID: udid,
            nowNanoseconds: 10
        ).event)
        XCTAssertEqual(reassembler.acceptRecoveryEvent(
            recovery,
            expectedUDID: udid,
            nowNanoseconds: 11
        ).event, recovery)
        XCTAssertNil(reassembler.accept(
            second,
            encodedBytes: 100,
            expectedUDID: udid,
            nowNanoseconds: 12
        ).event)
    }

    func testRecoverySupersedesExpiredPartialAndTombstonesLateChunks() {
        let udid = "SIM-EXPIRED"
        let event = makeEvent(udid: udid)
        let first = RecordedTouchEventDatagram(
            event: copy(event, samples: [event.samples[0]]),
            chunkIndex: 0,
            chunkCount: 2
        )
        let second = RecordedTouchEventDatagram(
            event: copy(event, samples: [event.samples[1]]),
            chunkIndex: 1,
            chunkCount: 2
        )
        let recovery = copy(event, samples: [event.samples[1]])
        var reassembler = RecordedTouchEventReassembler()

        _ = reassembler.accept(first, encodedBytes: 100, expectedUDID: udid, nowNanoseconds: 0)
        let diagnostics = reassembler.expire(
            nowNanoseconds: RecordedTouchEventReassembler.assemblyTimeoutNanoseconds
        )
        XCTAssertEqual(diagnostics.map(\.kind), [.incompleteEventDiscarded])
        let recoveryUptime = RecordedTouchEventReassembler.assemblyTimeoutNanoseconds + 1
        XCTAssertEqual(reassembler.acceptRecoveryEvent(
            recovery,
            expectedUDID: udid,
            nowNanoseconds: recoveryUptime
        ).event, recovery)
        XCTAssertNil(reassembler.accept(
            second,
            encodedBytes: 100,
            expectedUDID: udid,
            nowNanoseconds: recoveryUptime + 1
        ).event)
        XCTAssertNil(reassembler.acceptRecoveryEvent(
            recovery,
            expectedUDID: udid,
            nowNanoseconds: recoveryUptime + 2
        ).event)
    }

    func testRecoveryRefreshesDeduplicationAfterDiscardDeadline() {
        let udid = "SIM-RECOVERY-DEADLINE"
        let event = makeEvent(udid: udid)
        let invalid = RecordedTouchEventDatagram(
            event: event,
            chunkIndex: 0,
            chunkCount: RecordedTouchEventReassembler.maximumChunkCount + 1
        )
        let replay = RecordedTouchEventDatagram(
            event: event,
            chunkIndex: 0,
            chunkCount: 1
        )
        let recovery = copy(event, samples: [event.samples[1]])
        var reassembler = RecordedTouchEventReassembler()
        let recoveryUptime = RecordedTouchEventReassembler.tombstoneLifetimeNanoseconds - 1

        XCTAssertNil(reassembler.accept(
            invalid,
            encodedBytes: 100,
            expectedUDID: udid,
            nowNanoseconds: 0
        ).event)
        XCTAssertEqual(reassembler.acceptRecoveryEvent(
            recovery,
            expectedUDID: udid,
            nowNanoseconds: recoveryUptime
        ).event, recovery)
        XCTAssertNil(reassembler.accept(
            replay,
            encodedBytes: 100,
            expectedUDID: udid,
            nowNanoseconds: RecordedTouchEventReassembler.tombstoneLifetimeNanoseconds + 1
        ).event)
    }

    func testInvalidChunkBoundsAreRejectedBeforeAllocation() {
        let udid = "SIM-CHUNK-BOUNDS"
        let event = makeEvent(udid: udid)
        var reassembler = RecordedTouchEventReassembler()
        let invalid = RecordedTouchEventDatagram(
            event: event,
            chunkIndex: 0,
            chunkCount: RecordedTouchEventReassembler.maximumChunkCount + 1
        )

        let output = reassembler.accept(
            invalid,
            encodedBytes: 100,
            expectedUDID: udid,
            nowNanoseconds: 0
        )
        XCTAssertEqual(output.diagnostics.last?.kind, .invalidChunkMetadata)
        XCTAssertNil(output.event)
    }

    func testTerminalEventCacheStaysBoundedDuringUniqueEventFlood() {
        let udid = "SIM-TERMINAL-BOUND"
        var reassembler = RecordedTouchEventReassembler()

        for index in 0...RecordedTouchEventReassembler.maximumTerminalEventCount {
            let event = RecordedTouchEvent(
                udid: udid,
                dispatchUptimeNanoseconds: UInt64(index),
                samples: []
            )
            let datagram = RecordedTouchEventDatagram(
                event: event,
                chunkIndex: 0,
                chunkCount: 1
            )
            XCTAssertEqual(reassembler.accept(
                datagram,
                encodedBytes: 100,
                expectedUDID: udid,
                nowNanoseconds: UInt64(index)
            ).event, event)
        }

        XCTAssertEqual(
            reassembler.retainedTerminalEventCount,
            RecordedTouchEventReassembler.maximumTerminalEventCount
        )
    }

    func testMissingListenerIsNormalNoOpAndCreatesNoFilesystemState() {
        let base = makeBaseDirectoryURL()
        let event = makeEvent(udid: "SIM-NONE")

        let result = RecordedTouchEventPublisher(
            udid: event.udid,
            baseDirectory: base
        ).publish(event)

        XCTAssertEqual(result, .noListener)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
    }

    func testExistingEndpointDeliveryFailureIsObservable() throws {
        let base = makeBaseDirectoryURL()
        defer { removeTemporaryDirectory(base) }
        let event = makeEvent(udid: "SIM-BROKEN")
        let paths = RecordedTouchTransportPaths(udid: event.udid, baseDirectory: base)
        try paths.ensureSecureBaseDirectory()
        XCTAssertTrue(FileManager.default.createFile(atPath: paths.socketURL.path, contents: Data()))

        let result = RecordedTouchEventPublisher(
            udid: event.udid,
            baseDirectory: base
        ).publish(event)

        guard case .failed(let diagnostic) = result else {
            return XCTFail("Expected an observable delivery failure, got \(result)")
        }
        XCTAssertEqual(diagnostic.kind, .deliveryFailed)
    }

    func testSecondListenerForSameUDIDFailsFast() throws {
        let base = makeBaseDirectoryURL()
        defer { removeTemporaryDirectory(base) }
        let first = try RecordedTouchEventListener(
            udid: "SIM-EXCLUSIVE",
            baseDirectory: base,
            onEvent: { _ in }
        )
        defer { first.close() }

        XCTAssertThrowsError(
            try RecordedTouchEventListener(
                udid: "SIM-EXCLUSIVE",
                baseDirectory: base,
                onEvent: { _ in }
            )
        ) { error in
            guard case .listenerAlreadyActive(let udid, let pid) = error as? RecordedTouchListenerError else {
                return XCTFail("Expected listenerAlreadyActive, got \(error)")
            }
            XCTAssertEqual(udid, "SIM-EXCLUSIVE")
            XCTAssertEqual(pid, getpid())
        }
    }

    func testDeadOwnerIsReclaimedBeforeBinding() throws {
        let base = makeBaseDirectoryURL()
        defer { removeTemporaryDirectory(base) }
        let udid = "SIM-STALE"
        let paths = RecordedTouchTransportPaths(udid: udid, baseDirectory: base)
        try paths.ensureSecureBaseDirectory()
        let staleGeneration = RecordedTouchListenerGeneration(
            token: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        try Data(
            "\(deadPID)\n\(staleGeneration.token.uuidString)\n".utf8
        ).write(to: paths.pidfileURL)
        let staleRecoveryURL = paths.recoveryURL(for: staleGeneration)
        XCTAssertTrue(try RecordedTouchRecoveryJournal.appendTerminalEvent(
            makeSingleContactEvent(
                udid: udid,
                phase: .ended,
                dispatchUptimeNanoseconds: 1
            ),
            generation: staleGeneration,
            at: staleRecoveryURL
        ))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: paths.socketURL.path,
            contents: Data("stale".utf8)
        ))
        let staleSocketInode = inode(of: paths.socketURL)
        let delivered = expectation(description: "reclaimed listener received event")
        let event = makeEvent(udid: udid)

        let listener = try RecordedTouchEventListener(
            udid: udid,
            baseDirectory: base,
            onEvent: { received in
                XCTAssertEqual(received, event)
                delivered.fulfill()
            }
        )
        defer { listener.close() }

        XCTAssertNotEqual(inode(of: paths.socketURL), staleSocketInode)
        XCTAssertEqual(readPID(paths.pidfileURL), getpid())
        XCTAssertNotEqual(listener.generation, staleGeneration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRecoveryURL.path))
        XCTAssertEqual(
            RecordedTouchEventPublisher(udid: udid, baseDirectory: base).publish(event),
            .delivered
        )
        wait(for: [delivered], timeout: 2)
    }

    func testTerminalRecoveryIsNotQueuedAfterListenerGenerationChanges() throws {
        let base = makeBaseDirectoryURL()
        defer { removeTemporaryDirectory(base) }
        let udid = "SIM-RECOVERY-RESTART"
        let listeners = LockedBox<[RecordedTouchEventListener]>([
            try RecordedTouchEventListener(
                udid: udid,
                baseDirectory: base,
                onEvent: { _ in }
            ),
        ])
        defer {
            for listener in listeners.value {
                listener.close()
            }
        }
        let oldGeneration = listeners.value[0].generation
        let paths = listeners.value[0].paths
        let sender = RecordedTouchDatagramSender { _, _, _ in
            listeners.value[0].close()
            let replacement = try! RecordedTouchEventListener(
                udid: udid,
                baseDirectory: base,
                onEvent: { _ in }
            )
            listeners.withValue { $0.append(replacement) }
            return .failed(errorNumber: EAGAIN)
        }

        let result = RecordedTouchEventPublisher(
            udid: udid,
            baseDirectory: base,
            datagramSender: sender
        ).publish(makeSingleContactEvent(
            udid: udid,
            phase: .ended,
            dispatchUptimeNanoseconds: 10
        ))

        guard case .failed(let diagnostic) = result else {
            return XCTFail("Expected injected delivery failure")
        }
        XCTAssertEqual(diagnostic.kind, .deliveryFailed)
        XCTAssertFalse(diagnostic.message.contains("recovery queued"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.recoveryURL(for: oldGeneration).path
        ))
        XCTAssertNotEqual(listeners.value.last?.generation, oldGeneration)
    }

    func testLivePIDWithoutAnAcquiredSocketIsNotReclaimed() throws {
        let base = makeBaseDirectoryURL()
        defer { removeTemporaryDirectory(base) }
        let udid = "SIM-LIVE-OWNER"
        let paths = RecordedTouchTransportPaths(udid: udid, baseDirectory: base)
        try paths.ensureSecureBaseDirectory()
        try Data("\(getpid())\n".utf8).write(to: paths.pidfileURL)

        XCTAssertThrowsError(
            try RecordedTouchEventListener(udid: udid, baseDirectory: base, onEvent: { _ in })
        ) { error in
            guard case .listenerAlreadyActive(let actualUDID, let pid) = error as? RecordedTouchListenerError else {
                return XCTFail("Expected listenerAlreadyActive, got \(error)")
            }
            XCTAssertEqual(actualUDID, udid)
            XCTAssertEqual(pid, getpid())
        }
        XCTAssertEqual(readPID(paths.pidfileURL), getpid())
    }

    func testUnverifiableOwnerIsNotReclaimed() throws {
        let base = makeBaseDirectoryURL()
        defer { removeTemporaryDirectory(base) }
        let udid = "SIM-UNKNOWN-OWNER"
        let paths = RecordedTouchTransportPaths(udid: udid, baseDirectory: base)
        try paths.ensureSecureBaseDirectory()
        try Data("not-a-pid\n".utf8).write(to: paths.pidfileURL)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: paths.socketURL.path,
            contents: Data("unknown-owner".utf8)
        ))

        XCTAssertThrowsError(
            try RecordedTouchEventListener(udid: udid, baseDirectory: base, onEvent: { _ in })
        ) { error in
            guard case .ownerCannotBeVerified = error as? RecordedTouchListenerError else {
                return XCTFail("Expected ownerCannotBeVerified, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: paths.socketURL), Data("unknown-owner".utf8))
    }

    func testOwnerlessEndpointFailsWithoutLeavingAClaimFile() throws {
        let base = makeBaseDirectoryURL()
        defer { removeTemporaryDirectory(base) }
        let udid = "SIM-OWNERLESS"
        let paths = RecordedTouchTransportPaths(udid: udid, baseDirectory: base)
        try paths.ensureSecureBaseDirectory()
        let endpointData = Data("ownerless".utf8)
        try endpointData.write(to: paths.socketURL)

        XCTAssertThrowsError(
            try RecordedTouchEventListener(udid: udid, baseDirectory: base, onEvent: { _ in })
        ) { error in
            guard case .endpointHasNoOwner = error as? RecordedTouchListenerError else {
                return XCTFail("Expected endpointHasNoOwner, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pidfileURL.path))
        XCTAssertEqual(try Data(contentsOf: paths.socketURL), endpointData)
    }

    func testCloseRemovesOwnedStateAndAllowsRebindWithoutReplay() throws {
        let base = makeBaseDirectoryURL()
        defer { removeTemporaryDirectory(base) }
        let udid = "SIM-REBIND"
        let firstEvent = makeEvent(udid: udid)
        let first = try RecordedTouchEventListener(
            udid: udid,
            baseDirectory: base,
            onEvent: { _ in }
        )
        let paths = first.paths
        XCTAssertEqual(
            RecordedTouchEventPublisher(udid: udid, baseDirectory: base).publish(firstEvent),
            .delivered
        )

        first.close()
        first.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.socketURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pidfileURL.path))
        XCTAssertEqual(
            RecordedTouchEventPublisher(udid: udid, baseDirectory: base).publish(firstEvent),
            .noListener
        )

        let secondEvent = makeEvent(udid: udid)
        let rebound = expectation(description: "rebound listener received only new event")
        let second = try RecordedTouchEventListener(
            udid: udid,
            baseDirectory: base,
            onEvent: { event in
                XCTAssertEqual(event.eventID, secondEvent.eventID)
                rebound.fulfill()
            }
        )
        defer { second.close() }
        XCTAssertEqual(
            RecordedTouchEventPublisher(udid: udid, baseDirectory: base).publish(secondEvent),
            .delivered
        )
        wait(for: [rebound], timeout: 2)
    }

    func testCloseDoesNotRemovePathsTakenOverByAnotherOwner() throws {
        let base = makeBaseDirectoryURL()
        defer { removeTemporaryDirectory(base) }
        let udid = "SIM-TAKEOVER"
        let listener = try RecordedTouchEventListener(
            udid: udid,
            baseDirectory: base,
            onEvent: { _ in }
        )
        let paths = listener.paths

        try FileManager.default.removeItem(at: paths.socketURL)
        try FileManager.default.removeItem(at: paths.pidfileURL)
        let replacementSocket = Data("replacement-socket".utf8)
        let replacementPID = Data("\(getpid())\n".utf8)
        try replacementSocket.write(to: paths.socketURL)
        try replacementPID.write(to: paths.pidfileURL)

        listener.close()

        XCTAssertEqual(try Data(contentsOf: paths.socketURL), replacementSocket)
        XCTAssertEqual(try Data(contentsOf: paths.pidfileURL), replacementPID)
    }

    func testMalformedWrongUDIDAndWrongVersionDatagramsAreDiagnosedAndIgnored() throws {
        let base = makeBaseDirectoryURL()
        defer { removeTemporaryDirectory(base) }
        let udid = "SIM-VALIDATION"
        let diagnostics = expectation(description: "three rejected datagrams diagnosed")
        diagnostics.expectedFulfillmentCount = 3
        let diagnosticKinds = LockedBox<[RecordedTouchTransportDiagnostic.Kind]>([])
        let validDelivered = expectation(description: "listener remains usable")
        let validEvent = makeEvent(udid: udid)

        let listener = try RecordedTouchEventListener(
            udid: udid,
            baseDirectory: base,
            onEvent: { event in
                XCTAssertEqual(event, validEvent)
                validDelivered.fulfill()
            },
            onDiagnostic: { diagnostic in
                diagnosticKinds.withValue { $0.append(diagnostic.kind) }
                diagnostics.fulfill()
            }
        )
        defer { listener.close() }

        try sendRawDatagram(Data("{".utf8), to: listener.paths.socketURL.path)
        try sendRawDatagram(
            JSONEncoder().encode(RecordedTouchEventDatagram(
                event: makeEvent(udid: "OTHER-UDID"),
                chunkIndex: 0,
                chunkCount: 1
            )),
            to: listener.paths.socketURL.path
        )
        let wrongVersion = RecordedTouchEvent(
            version: RecordedTouchEvent.currentVersion + 1,
            udid: udid,
            dispatchUptimeNanoseconds: 1,
            samples: []
        )
        try sendRawDatagram(
            JSONEncoder().encode(RecordedTouchEventDatagram(
                event: wrongVersion,
                chunkIndex: 0,
                chunkCount: 1
            )),
            to: listener.paths.socketURL.path
        )

        wait(for: [diagnostics], timeout: 2)
        XCTAssertEqual(
            diagnosticKinds.value.map(\.rawValue).sorted(),
            [
                RecordedTouchTransportDiagnostic.Kind.malformedPayload.rawValue,
                RecordedTouchTransportDiagnostic.Kind.udidMismatch.rawValue,
                RecordedTouchTransportDiagnostic.Kind.versionMismatch.rawValue,
            ].sorted()
        )

        XCTAssertEqual(
            RecordedTouchEventPublisher(udid: udid, baseDirectory: base).publish(validEvent),
            .delivered
        )
        wait(for: [validDelivered], timeout: 2)
    }

    func testPublisherRejectsWrongUDIDAndUnorderedSamplesWithoutTouchingEndpoint() throws {
        let base = makeBaseDirectoryURL()
        defer { removeTemporaryDirectory(base) }
        let udid = "SIM-PUBLISH-VALIDATION"
        let listener = try RecordedTouchEventListener(
            udid: udid,
            baseDirectory: base,
            onEvent: { _ in XCTFail("Publisher must not send an invalid event") }
        )
        defer { listener.close() }

        let wrongUDID = makeEvent(udid: "OTHER")
        guard case .failed(let udidDiagnostic) = RecordedTouchEventPublisher(
            udid: udid,
            baseDirectory: base
        ).publish(wrongUDID) else {
            return XCTFail("Expected wrong-UDID publish to fail validation")
        }
        XCTAssertEqual(udidDiagnostic.kind, .udidMismatch)

        let unordered = RecordedTouchEvent(
            udid: udid,
            dispatchUptimeNanoseconds: 1,
            samples: [
                .init(relativeNanoseconds: 2, contacts: []),
                .init(relativeNanoseconds: 1, contacts: []),
            ]
        )
        guard case .failed(let orderDiagnostic) = RecordedTouchEventPublisher(
            udid: udid,
            baseDirectory: base
        ).publish(unordered) else {
            return XCTFail("Expected unordered publish to fail validation")
        }
        XCTAssertEqual(orderDiagnostic.kind, .unorderedSamples)
    }

    private func makeEvent(udid: String) -> RecordedTouchEvent {
        RecordedTouchEvent(
            udid: udid,
            dispatchUptimeNanoseconds: 10_000,
            samples: [
                .init(relativeNanoseconds: 0, contacts: [
                    .init(contactID: 0, phase: .began, x: 100, y: 200),
                ]),
                .init(relativeNanoseconds: 50_000_000, contacts: [
                    .init(contactID: 0, phase: .ended, x: 100, y: 200),
                ]),
            ]
        )
    }

    private func makeSingleContactEvent(
        udid: String,
        phase: RecordedTouchPhase,
        dispatchUptimeNanoseconds: UInt64
    ) -> RecordedTouchEvent {
        RecordedTouchEvent(
            udid: udid,
            dispatchUptimeNanoseconds: dispatchUptimeNanoseconds,
            samples: [RecordedTouchSample(
                relativeNanoseconds: 0,
                contacts: [RecordedTouchContact(
                    contactID: 0,
                    phase: phase,
                    x: 100,
                    y: 200
                )]
            )]
        )
    }

    private func copy(
        _ event: RecordedTouchEvent,
        samples: [RecordedTouchSample]
    ) -> RecordedTouchEvent {
        RecordedTouchEvent(
            version: event.version,
            udid: event.udid,
            eventID: event.eventID,
            dispatchUptimeNanoseconds: event.dispatchUptimeNanoseconds,
            samples: samples
        )
    }

    private func makeBaseDirectoryURL() -> URL {
        URL(
            fileURLWithPath: "/tmp/sim-use-touch-tests-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
    }

    private func removeTemporaryDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func mode(of url: URL) -> mode_t {
        var fileStat = stat()
        XCTAssertEqual(lstat(url.path, &fileStat), 0)
        return fileStat.st_mode
    }

    private func inode(of url: URL) -> ino_t {
        var fileStat = stat()
        XCTAssertEqual(lstat(url.path, &fileStat), 0)
        return fileStat.st_ino
    }

    private func readPID(_ url: URL) -> pid_t? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        guard let firstLine = text.split(whereSeparator: \.isNewline).first else {
            return nil
        }
        return pid_t(firstLine)
    }

    private func sendRawDatagram(_ data: Data, to path: String) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXTestError(operation: "socket", errorNumber: errno) }
        defer { Darwin.close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                tuplePointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    let count = strlen(source)
                    memcpy(destination, source, count)
                    destination[count] = 0
                }
            }
        }

        let sent = data.withUnsafeBytes { bytes -> Int in
            withUnsafePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.sendto(
                        fd,
                        bytes.baseAddress,
                        bytes.count,
                        0,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
        }
        guard sent == data.count else {
            throw POSIXTestError(operation: "sendto", errorNumber: errno)
        }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storedValue)
    }
}

private struct POSIXTestError: Error, CustomStringConvertible {
    let operation: String
    let errorNumber: Int32

    var description: String {
        "\(operation) failed (errno=\(errorNumber)): \(String(cString: strerror(errorNumber)))"
    }
}
