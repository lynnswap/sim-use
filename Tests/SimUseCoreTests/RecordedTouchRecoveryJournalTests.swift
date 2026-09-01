// SPDX-License-Identifier: Apache-2.0
@testable import SimUseCore
import Darwin
import Foundation
import XCTest

final class RecordedTouchRecoveryJournalTests: XCTestCase {
    private let generation = RecordedTouchListenerGeneration(
        token: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    )

    func testNonTerminalEventDoesNotCreateAMailbox() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailboxURL = directory.appendingPathComponent("touch.recovery")

        XCTAssertFalse(try RecordedTouchRecoveryJournal.appendTerminalEvent(
            makeEvent(phase: .began, contactID: 0, uptime: 1),
            generation: generation,
            at: mailboxURL
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mailboxURL.path))
    }

    func testTerminalEventRoundTripsThroughPrivateAtomicFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailboxURL = directory.appendingPathComponent("touch.recovery")
        let event = makeEvent(phase: .ended, contactID: 0, uptime: 10)

        XCTAssertTrue(try RecordedTouchRecoveryJournal.appendTerminalEvent(
            event,
            generation: generation,
            at: mailboxURL
        ))
        XCTAssertEqual(mode(of: mailboxURL) & 0o777, 0o700)
        let eventURL = try XCTUnwrap(eventURLs(in: mailboxURL).first)
        XCTAssertEqual(mode(of: eventURL) & 0o777, 0o600)

        let batch = try XCTUnwrap(RecordedTouchRecoveryJournal.consume(
            generation: generation,
            at: mailboxURL
        ))
        XCTAssertEqual(batch.events, [event])
        XCTAssertTrue(batch.diagnostics.isEmpty)
        XCTAssertNil(try RecordedTouchRecoveryJournal.consume(
            generation: generation,
            at: mailboxURL
        ))
    }

    func testMailboxCapacityPreservesQueuedEventsAndExactTimestamps() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailboxURL = directory.appendingPathComponent("touch.recovery")
        let events = (0..<RecordedTouchRecoveryJournal.maximumEventCount).map {
            makeEvent(
                phase: .ended,
                contactID: UInt32($0 % 3),
                uptime: UInt64($0) * 10
            )
        }
        for event in events {
            XCTAssertTrue(try RecordedTouchRecoveryJournal.appendTerminalEvent(
                event,
                generation: generation,
                at: mailboxURL
            ))
        }
        let overflow = makeEvent(
            phase: .cancelled,
            contactID: 0,
            uptime: UInt64(RecordedTouchRecoveryJournal.maximumEventCount) * 10
        )
        XCTAssertTrue(try RecordedTouchRecoveryJournal.appendTerminalEvent(
            overflow,
            generation: generation,
            at: mailboxURL
        ))

        let batch = try XCTUnwrap(RecordedTouchRecoveryJournal.consume(
            generation: generation,
            at: mailboxURL
        ))
        XCTAssertEqual(
            batch.events.count,
            RecordedTouchRecoveryJournal.maximumEventCount + 1
        )
        XCTAssertTrue(batch.diagnostics.isEmpty)
        XCTAssertEqual(
            batch.events.map(\.dispatchUptimeNanoseconds),
            (events + [overflow]).map(\.dispatchUptimeNanoseconds)
        )
        XCTAssertTrue(try RecordedTouchRecoveryJournal.appendTerminalEvent(
            overflow,
            generation: generation,
            at: mailboxURL
        ))
        XCTAssertEqual(
            try RecordedTouchRecoveryJournal.consume(
                generation: generation,
                at: mailboxURL
            )?.events,
            [overflow]
        )
    }

    func testAbandonedPendingSlotIsReclaimed() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailboxURL = directory.appendingPathComponent("touch.recovery")
        let seed = makeEvent(phase: .ended, contactID: 0, uptime: 1)
        XCTAssertTrue(try RecordedTouchRecoveryJournal.appendTerminalEvent(
            seed,
            generation: generation,
            at: mailboxURL
        ))
        _ = try RecordedTouchRecoveryJournal.consume(
            generation: generation,
            at: mailboxURL
        )
        let pendingURL = mailboxURL.appendingPathComponent("slot-00.pending")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: pendingURL.path,
            contents: Data("partial".utf8)
        ))

        XCTAssertNil(try RecordedTouchRecoveryJournal.consume(
            generation: generation,
            at: mailboxURL
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
        XCTAssertTrue(try RecordedTouchRecoveryJournal.appendTerminalEvent(
            makeEvent(phase: .cancelled, contactID: 1, uptime: 2),
            generation: generation,
            at: mailboxURL
        ))
    }

    func testMalformedFinalSlotIsDiagnosedAndReclaimed() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailboxURL = directory.appendingPathComponent("touch.recovery")
        let seed = makeEvent(phase: .ended, contactID: 0, uptime: 1)
        XCTAssertTrue(try RecordedTouchRecoveryJournal.appendTerminalEvent(
            seed,
            generation: generation,
            at: mailboxURL
        ))
        _ = try RecordedTouchRecoveryJournal.consume(
            generation: generation,
            at: mailboxURL
        )
        let malformedURL = mailboxURL.appendingPathComponent("slot-00.json")
        try Data("{".utf8).write(to: malformedURL)

        let batch = try XCTUnwrap(RecordedTouchRecoveryJournal.consume(
            generation: generation,
            at: mailboxURL
        ))
        XCTAssertTrue(batch.events.isEmpty)
        XCTAssertEqual(batch.diagnostics.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: malformedURL.path))
    }

    func testGenerationMismatchIsDiagnosedAndRemoved() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailboxURL = directory.appendingPathComponent("touch.recovery")
        XCTAssertTrue(try RecordedTouchRecoveryJournal.appendTerminalEvent(
            makeEvent(phase: .ended, contactID: 0, uptime: 10),
            generation: generation,
            at: mailboxURL
        ))

        let batch = try XCTUnwrap(RecordedTouchRecoveryJournal.consume(
            generation: RecordedTouchListenerGeneration(
                token: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            ),
            at: mailboxURL
        ))
        XCTAssertTrue(batch.events.isEmpty)
        XCTAssertEqual(batch.diagnostics.count, 1)
        XCTAssertTrue(batch.diagnostics[0].contains("different listener generation"))
        XCTAssertNil(try RecordedTouchRecoveryJournal.consume(
            generation: generation,
            at: mailboxURL
        ))
    }

    func testEmergencySlotsKeepLatestTerminalPerContact() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailboxURL = directory.appendingPathComponent("touch.recovery")
        for index in 0..<RecordedTouchRecoveryJournal.maximumEventCount {
            XCTAssertTrue(try RecordedTouchRecoveryJournal.appendTerminalEvent(
                makeEvent(
                    phase: .ended,
                    contactID: 2,
                    uptime: UInt64(index)
                ),
                generation: generation,
                at: mailboxURL
            ))
        }
        for event in [
            makeEvent(phase: .ended, contactID: 0, uptime: 100),
            makeEvent(phase: .ended, contactID: 1, uptime: 200),
            makeEvent(phase: .cancelled, contactID: 0, uptime: 300),
        ] {
            XCTAssertTrue(try RecordedTouchRecoveryJournal.appendTerminalEvent(
                event,
                generation: generation,
                at: mailboxURL
            ))
        }

        let batch = try XCTUnwrap(RecordedTouchRecoveryJournal.consume(
            generation: generation,
            at: mailboxURL
        ))
        let emergencyEvents = batch.events.filter {
            $0.dispatchUptimeNanoseconds >= 100
        }
        XCTAssertEqual(
            emergencyEvents.map(\.dispatchUptimeNanoseconds),
            [200, 300]
        )
        XCTAssertEqual(
            emergencyEvents.map { $0.samples[0].contacts[0].contactID },
            [1, 0]
        )
    }

    func testEmergencyPublishUsesAnotherCandidateWhenOneWriterIsBusy() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailboxURL = directory.appendingPathComponent("touch.recovery")
        try fillMainSlots(in: mailboxURL)
        let busyLockURL = mailboxURL.appendingPathComponent("emergency-0-00.lock")
        let busyFD = Darwin.open(
            busyLockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        XCTAssertGreaterThanOrEqual(busyFD, 0)
        defer { Darwin.close(busyFD) }
        XCTAssertEqual(flock(busyFD, LOCK_EX | LOCK_NB), 0)
        let terminal = makeEvent(
            phase: .ended,
            contactID: 0,
            uptime: 1_000
        )

        XCTAssertTrue(try RecordedTouchRecoveryJournal.appendTerminalEvent(
            terminal,
            generation: generation,
            at: mailboxURL
        ))
        XCTAssertEqual(flock(busyFD, LOCK_UN), 0)
        let batch = try XCTUnwrap(RecordedTouchRecoveryJournal.consume(
            generation: generation,
            at: mailboxURL
        ))
        XCTAssertTrue(batch.events.contains {
            $0.dispatchUptimeNanoseconds == terminal.dispatchUptimeNanoseconds
        })
    }

    func testConcurrentEmergencyCandidatesDeliverOnlyNewestContactTerminal() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailboxURL = directory.appendingPathComponent("touch.recovery")
        try fillMainSlots(in: mailboxURL)
        let firstLockURL = mailboxURL.appendingPathComponent("emergency-0-00.lock")
        let firstFD = Darwin.open(
            firstLockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        XCTAssertGreaterThanOrEqual(firstFD, 0)
        defer { Darwin.close(firstFD) }
        XCTAssertEqual(flock(firstFD, LOCK_EX | LOCK_NB), 0)
        let newer = makeEvent(
            phase: .ended,
            contactID: 0,
            uptime: 2_000
        )
        XCTAssertTrue(try RecordedTouchRecoveryJournal.appendTerminalEvent(
            newer,
            generation: generation,
            at: mailboxURL
        ))
        XCTAssertEqual(flock(firstFD, LOCK_UN), 0)
        let older = makeEvent(
            phase: .ended,
            contactID: 0,
            uptime: 1_000
        )
        XCTAssertTrue(try RecordedTouchRecoveryJournal.appendTerminalEvent(
            older,
            generation: generation,
            at: mailboxURL
        ))

        let batch = try XCTUnwrap(RecordedTouchRecoveryJournal.consume(
            generation: generation,
            at: mailboxURL
        ))
        XCTAssertEqual(
            batch.events.filter {
                $0.dispatchUptimeNanoseconds >= 1_000
            }.map(\.dispatchUptimeNanoseconds),
            [2_000]
        )
    }

    func testEmergencyArtifactCanBeRemovedBySourceEventID() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailboxURL = directory.appendingPathComponent("touch.recovery")
        try fillMainSlots(in: mailboxURL)
        let terminal = makeEvent(
            phase: .cancelled,
            contactID: 0,
            uptime: 1_000
        )
        XCTAssertTrue(try RecordedTouchRecoveryJournal.appendTerminalEvent(
            terminal,
            generation: generation,
            at: mailboxURL
        ))

        RecordedTouchRecoveryJournal.remove(event: terminal, at: mailboxURL)
        let batch = try XCTUnwrap(RecordedTouchRecoveryJournal.consume(
            generation: generation,
            at: mailboxURL
        ))
        XCTAssertFalse(batch.events.contains {
            $0.dispatchUptimeNanoseconds == terminal.dispatchUptimeNanoseconds
        })
    }

    func testBusyContactDoesNotPreventAnotherContactRecovery() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailboxURL = directory.appendingPathComponent("touch.recovery")
        try fillMainSlots(in: mailboxURL)
        var busyFDs: [Int32] = []
        defer {
            for fd in busyFDs {
                _ = flock(fd, LOCK_UN)
                Darwin.close(fd)
            }
        }
        for candidate in 0..<RecordedTouchRecoveryJournal.emergencyCandidateCount {
            let url = mailboxURL.appendingPathComponent(
                String(format: "emergency-1-%02d.lock", candidate)
            )
            let fd = Darwin.open(
                url.path,
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
            XCTAssertGreaterThanOrEqual(fd, 0)
            XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
            busyFDs.append(fd)
        }
        let terminal = RecordedTouchEvent(
            udid: "SIM-RECOVERY-JOURNAL",
            dispatchUptimeNanoseconds: 1_000,
            samples: [RecordedTouchSample(
                relativeNanoseconds: 0,
                contacts: [
                    RecordedTouchContact(
                        contactID: 1,
                        phase: .ended,
                        x: 10,
                        y: 10
                    ),
                    RecordedTouchContact(
                        contactID: 2,
                        phase: .ended,
                        x: 20,
                        y: 20
                    ),
                ]
            )]
        )
        let start = DispatchTime.now().uptimeNanoseconds

        XCTAssertThrowsError(try RecordedTouchRecoveryJournal.appendTerminalEvent(
            terminal,
            generation: generation,
            at: mailboxURL
        )) { error in
            XCTAssertEqual(
                error as? RecordedTouchRecoveryJournalError,
                .mailboxFull(
                    limit: RecordedTouchRecoveryJournal.emergencyCandidateCount
                )
            )
        }
        XCTAssertLessThan(
            DispatchTime.now().uptimeNanoseconds - start,
            500_000_000
        )
        let batch = try XCTUnwrap(RecordedTouchRecoveryJournal.consume(
            generation: generation,
            at: mailboxURL
        ))
        XCTAssertTrue(batch.events.contains { event in
            event.dispatchUptimeNanoseconds == 1_000
                && event.samples[0].contacts[0].contactID == 2
        })
    }

    func testConcurrentPublishersUseIndependentEventFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailboxURL = directory.appendingPathComponent("touch.recovery")
        let eventCount = 32
        let errors = RecoveryJournalErrorBox()
        let group = DispatchGroup()
        let generation = generation
        let events = (0..<eventCount).map { index in
            makeEvent(
                phase: .ended,
                contactID: UInt32(index % 3),
                uptime: UInt64(index)
            )
        }
        for event in events {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    _ = try RecordedTouchRecoveryJournal.appendTerminalEvent(
                        event,
                        generation: generation,
                        at: mailboxURL
                    )
                } catch {
                    errors.append(error)
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(errors.values.isEmpty, "\(errors.values)")

        var recovered: [RecordedTouchEvent] = []
        while let batch = try RecordedTouchRecoveryJournal.consume(
            generation: generation,
            at: mailboxURL
        ) {
            XCTAssertTrue(batch.diagnostics.isEmpty)
            recovered.append(contentsOf: batch.events)
        }
        XCTAssertEqual(recovered.count, eventCount)
        XCTAssertEqual(
            Set(recovered.map(\.dispatchUptimeNanoseconds)),
            Set((0..<eventCount).map(UInt64.init))
        )
    }

    private func makeEvent(
        phase: RecordedTouchPhase,
        contactID: UInt32,
        uptime: UInt64
    ) -> RecordedTouchEvent {
        RecordedTouchEvent(
            udid: "SIM-RECOVERY-JOURNAL",
            dispatchUptimeNanoseconds: uptime,
            samples: [RecordedTouchSample(
                relativeNanoseconds: 0,
                contacts: [RecordedTouchContact(
                    contactID: contactID,
                    phase: phase,
                    x: Double(contactID),
                    y: Double(contactID)
                )]
            )]
        )
    }

    private func fillMainSlots(in mailboxURL: URL) throws {
        for index in 0..<RecordedTouchRecoveryJournal.maximumEventCount {
            XCTAssertTrue(try RecordedTouchRecoveryJournal.appendTerminalEvent(
                makeEvent(
                    phase: .ended,
                    contactID: 2,
                    uptime: UInt64(index)
                ),
                generation: generation,
                at: mailboxURL
            ))
        }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sim-use-touch-recovery-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        return url
    }

    private func eventURLs(in mailboxURL: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: mailboxURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
    }

    private func mode(of url: URL) -> mode_t {
        var fileStat = stat()
        XCTAssertEqual(lstat(url.path, &fileStat), 0)
        return fileStat.st_mode
    }
}

private final class RecoveryJournalErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Error] = []

    var values: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ error: Error) {
        lock.lock()
        storedValues.append(error)
        lock.unlock()
    }
}
