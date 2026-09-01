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
        XCTAssertEqual(mode(of: listener.paths.socketURL) & 0o777, 0o600)
        XCTAssertEqual(mode(of: listener.paths.pidfileURL) & 0o777, 0o600)

        let result = RecordedTouchEventPublisher(
            udid: event.udid,
            baseDirectory: base
        ).publish(event)
        XCTAssertEqual(result, .delivered)
        wait(for: [received], timeout: 2)
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

        let receivedEvents = LockedBox<[RecordedTouchEvent]>([])
        let receivedAllSamples = expectation(description: "listener received every chunk")
        let listener = try RecordedTouchEventListener(
            udid: udid,
            baseDirectory: base,
            onEvent: { received in
                receivedEvents.withValue { events in
                    events.append(received)
                    if events.reduce(0, { $0 + $1.samples.count }) == expectedSamples.count {
                        receivedAllSamples.fulfill()
                    }
                }
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
        wait(for: [receivedAllSamples], timeout: 2)

        let delivered = receivedEvents.value
        XCTAssertGreaterThan(delivered.count, 1)
        XCTAssertTrue(delivered.allSatisfy { $0.eventID == event.eventID })
        XCTAssertEqual(delivered.flatMap(\.samples), expectedSamples)
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
        try createSecureDirectory(base)
        let event = makeEvent(udid: "SIM-BROKEN")
        let paths = RecordedTouchTransportPaths(udid: event.udid, baseDirectory: base)
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
        try createSecureDirectory(base)
        let udid = "SIM-STALE"
        let paths = RecordedTouchTransportPaths(udid: udid, baseDirectory: base)
        try Data("\(deadPID)\n".utf8).write(to: paths.pidfileURL)
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
        XCTAssertEqual(
            RecordedTouchEventPublisher(udid: udid, baseDirectory: base).publish(event),
            .delivered
        )
        wait(for: [delivered], timeout: 2)
    }

    func testLivePIDWithoutAnAcquiredSocketIsNotReclaimed() throws {
        let base = makeBaseDirectoryURL()
        defer { removeTemporaryDirectory(base) }
        try createSecureDirectory(base)
        let udid = "SIM-LIVE-OWNER"
        let paths = RecordedTouchTransportPaths(udid: udid, baseDirectory: base)
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
        try createSecureDirectory(base)
        let udid = "SIM-UNKNOWN-OWNER"
        let paths = RecordedTouchTransportPaths(udid: udid, baseDirectory: base)
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
        try createSecureDirectory(base)
        let udid = "SIM-OWNERLESS"
        let paths = RecordedTouchTransportPaths(udid: udid, baseDirectory: base)
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
            JSONEncoder().encode(makeEvent(udid: "OTHER-UDID")),
            to: listener.paths.socketURL.path
        )
        let wrongVersion = RecordedTouchEvent(
            version: RecordedTouchEvent.currentVersion + 1,
            udid: udid,
            dispatchUptimeNanoseconds: 1,
            samples: []
        )
        try sendRawDatagram(JSONEncoder().encode(wrongVersion), to: listener.paths.socketURL.path)

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

    private func makeBaseDirectoryURL() -> URL {
        URL(
            fileURLWithPath: "/tmp/sim-use-touch-tests-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
    }

    private func createSecureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
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
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
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
