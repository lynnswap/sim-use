// SPDX-License-Identifier: Apache-2.0
@testable import iOSSimBackend
import Darwin
import Dispatch
import Foundation
import SimUseCore
import Testing

@Suite("Recorded touch stream bridge")
struct RecordedTouchStreamBridgeTests {
    @Test("Enqueue delivers before flush and flush reports its outcome")
    func enqueueStartsBackgroundDelivery() throws {
        let fixture = try Fixture(udid: "BACKGROUND")
        defer { fixture.remove() }
        let inputs = InputCollector()
        let listener = try fixture.listener(onInput: { input in inputs.append(input) })
        defer { listener.close() }
        let publisher = fixture.publisher()

        #expect(publisher.enqueue(try primitive(timestamp: 42)) == .enqueued)
        #expect(inputs.waitForCount(1))
        #expect(publisher.flush() == .delivered)
        #expect(publisher.close() == .explicit)
    }

    @Test("Flush waits for the scheduled drain and returns its outcome")
    func flushWaitsForScheduledDrain() throws {
        let fixture = try Fixture(udid: "FLUSH-BARRIER")
        defer { fixture.remove() }
        let connectGate = ConnectGate()
        let publisher = fixture.publisher(
            connector: .init { _ in connectGate.connect() }
        )
        let publisherBox = PublisherBox(publisher)
        let flushProbe = FlushProbe()
        let worker = DispatchQueue(label: "com.lycorp.sim-use.tests.touch-flush")

        #expect(publisher.enqueue(try primitive(timestamp: 42)) == .enqueued)
        #expect(connectGate.waitUntilStarted())
        worker.async {
            flushProbe.markStarted()
            flushProbe.finish(publisherBox.value.flush())
        }
        #expect(flushProbe.waitUntilStarted())
        #expect(!flushProbe.isFinished)

        connectGate.release()
        #expect(flushProbe.waitUntilFinished())
        #expect(flushProbe.result == .noListener)
        worker.sync {}
        #expect(publisher.close() == .explicit)
    }

    @Test("Publisher socket writes fail instead of blocking on backpressure", .timeLimit(.minutes(1)))
    func publisherSocketIsNonBlocking() {
        var sockets = [Int32](repeating: -1, count: 2)
        #expect(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        guard sockets.allSatisfy({ $0 >= 0 }) else { return }
        defer {
            Darwin.close(sockets[0])
            Darwin.close(sockets[1])
        }

        #expect(RecordedTouchStreamSocket.configurePublisherFD(sockets[0]))
        let statusFlags = fcntl(sockets[0], F_GETFL, 0)
        #expect(statusFlags & O_NONBLOCK != 0)

        let payload = Data(repeating: 0, count: 1024 * 1024)
        var failure: Int32?
        for _ in 0..<16 {
            let result = DaemonSocket.writeAll(fd: sockets[0], data: payload)
            if !result.ok {
                failure = result.lastErrno
                break
            }
        }
        #expect(failure == EAGAIN || failure == EWOULDBLOCK)
    }

    @Test("Primitive boundary admits exactly one or two contacts")
    func primitiveContactBounds() throws {
        let contact = RecordedTouchPrimitive.Contact(localID: 0, x: 10, y: 20)
        #expect(throws: RecordedTouchPrimitiveError.invalidContactCount(0)) {
            _ = try RecordedTouchPrimitive(
                dispatchUptimeNanoseconds: 1,
                phase: .down,
                contacts: []
            )
        }
        #expect(throws: RecordedTouchPrimitiveError.invalidContactCount(3)) {
            _ = try RecordedTouchPrimitive(
                dispatchUptimeNanoseconds: 1,
                phase: .down,
                contacts: [contact, contact, contact]
            )
        }
        _ = try RecordedTouchPrimitive(
            dispatchUptimeNanoseconds: 1,
            phase: .down,
            contacts: [contact, contact]
        )
    }

    @Test("Publisher preserves enqueue order within one connection")
    func publisherPreservesOrder() throws {
        let fixture = try Fixture(udid: "ORDER")
        defer { fixture.remove() }
        let inputs = InputCollector()
        let listener = try fixture.listener(onInput: { input in inputs.append(input) })
        defer { listener.close() }
        let publisher = fixture.publisher()

        for timestamp in [UInt64(100), 200, 300] {
            #expect(publisher.enqueue(try primitive(timestamp: timestamp)) == .enqueued)
        }
        #expect(publisher.flush() == .delivered)
        #expect(inputs.waitForCount(3))

        let timestamps = inputs.values.compactMap { input -> UInt64? in
            guard case .update(_, let primitive) = input else { return nil }
            return primitive.dispatchUptimeNanoseconds
        }
        #expect(timestamps == [100, 200, 300])
        #expect(publisher.close() == .explicit)
    }

    @Test("Publisher identity scopes the same local contact ID")
    func publisherIdentityScopesLocalContactID() throws {
        let fixture = try Fixture(udid: "IDENTITY")
        defer { fixture.remove() }
        let inputs = InputCollector()
        let listener = try fixture.listener(onInput: { input in inputs.append(input) })
        defer { listener.close() }
        let firstID = UUID()
        let secondID = UUID()
        let first = fixture.publisher(publisherID: firstID)
        let second = fixture.publisher(publisherID: secondID)

        #expect(first.enqueue(try primitive(timestamp: 1, localID: 0)) == .enqueued)
        #expect(second.enqueue(try primitive(timestamp: 2, localID: 0)) == .enqueued)
        #expect(first.flush() == .delivered)
        #expect(second.flush() == .delivered)
        #expect(inputs.waitForCount(2))

        let identities = Set(inputs.values.compactMap { input -> PublisherContact? in
            guard case .update(let publisherID, let primitive) = input,
                  let contact = primitive.contacts.first else { return nil }
            return PublisherContact(publisherID: publisherID, localID: contact.localID)
        })
        #expect(identities == [
            PublisherContact(publisherID: firstID, localID: 0),
            PublisherContact(publisherID: secondID, localID: 0),
        ])

        _ = first.close()
        _ = second.close()
    }

    @Test("EOF emits one publisherClosed input")
    func eofEmitsPublisherClosedExactlyOnce() throws {
        let fixture = try Fixture(udid: "EOF")
        defer { fixture.remove() }
        let inputs = InputCollector()
        let publisherID = UUID()
        let listener = try fixture.listener(
            onInput: { input in inputs.append(input) },
            now: { 999 }
        )
        defer { listener.close() }
        let publisher = fixture.publisher(publisherID: publisherID)

        #expect(publisher.enqueue(try primitive(timestamp: 100)) == .enqueued)
        #expect(publisher.flush() == .delivered)
        #expect(publisher.close() == .explicit)
        #expect(inputs.waitForCount(2))
        #expect(publisher.close() == .explicit)

        listener.close()
        let closed = inputs.values.filter { input in
            guard case .publisherClosed(let id, let uptime) = input else { return false }
            return id == publisherID && uptime == 999
        }
        #expect(closed.count == 1)
    }

    @Test("Missing listener is a retryable no-op")
    func missingListenerIsRetryable() throws {
        let fixture = try Fixture(udid: "MISSING", createBaseDirectory: false)
        defer { fixture.remove() }
        let publisher = fixture.publisher()

        #expect(publisher.enqueue(try primitive(timestamp: 100)) == .enqueued)
        #expect(publisher.flush() == .noListener)

        let inputs = InputCollector()
        let listener = try fixture.listener(onInput: { input in inputs.append(input) })
        defer { listener.close() }
        #expect(publisher.enqueue(try primitive(timestamp: 200)) == .enqueued)
        #expect(publisher.flush() == .delivered)
        #expect(inputs.waitForCount(1))

        let delivered = inputs.values.compactMap { input -> UInt64? in
            guard case .update(_, let primitive) = input else { return nil }
            return primitive.dispatchUptimeNanoseconds
        }
        #expect(delivered == [200])
        _ = publisher.close()
    }

    @Test("Write failure terminates the connected publisher session")
    func writeFailureClosesPublisher() throws {
        let fixture = try Fixture(udid: "WRITE-FAILURE")
        defer { fixture.remove() }
        let inputs = InputCollector()
        let listener = try fixture.listener(onInput: { input in inputs.append(input) })
        let publisher = fixture.publisher()

        #expect(publisher.enqueue(try primitive(timestamp: 1)) == .enqueued)
        #expect(publisher.flush() == .delivered)
        #expect(inputs.waitForCount(1))
        listener.close()

        #expect(publisher.enqueue(try primitive(timestamp: 2)) == .enqueued)
        let failure = publisher.flush()
        guard case .closed(let terminalReason) = failure,
              case .writeFailed = terminalReason else {
            Issue.record("Expected write failure after the listener closed; got \(failure)")
            return
        }
        #expect(publisher.enqueue(try primitive(timestamp: 3)) == .closed(
            terminalReason
        ))
        #expect(publisher.close() == terminalReason)
    }

    @Test("Listener exclusively owns and removes its endpoint")
    func listenerOwnsEndpointResources() throws {
        let fixture = try Fixture(udid: "OWNERSHIP")
        defer { fixture.remove() }
        let listener = try fixture.listener(onInput: { _ in })

        #expect(FileManager.default.fileExists(atPath: listener.paths.socketURL.path))
        #expect(FileManager.default.fileExists(atPath: listener.paths.lockURL.path))
        #expect(throws: RecordedTouchStreamListenerError.self) {
            _ = try fixture.listener(onInput: { _ in })
        }

        listener.close()
        listener.close()
        #expect(!FileManager.default.fileExists(atPath: listener.paths.socketURL.path))
        #expect(!FileManager.default.fileExists(atPath: listener.paths.lockURL.path))
    }

    @Test("Outbound queue overflow terminates the publisher session")
    func outboundQueueOverflowClosesPublisher() throws {
        let fixture = try Fixture(udid: "OVERFLOW")
        defer { fixture.remove() }
        let gate = ConnectGate()
        let publisher = fixture.publisher(
            queueCapacity: 1,
            connector: .init { _ in gate.connect() }
        )

        #expect(publisher.enqueue(try primitive(timestamp: 1)) == .enqueued)
        #expect(gate.waitUntilStarted())
        #expect(publisher.enqueue(try primitive(timestamp: 2)) == .enqueued)
        #expect(publisher.enqueue(try primitive(timestamp: 3)) == .closed(
            .queueOverflow(capacity: 1)
        ))
        gate.release()
        #expect(publisher.close() == .queueOverflow(capacity: 1))
    }

    private func primitive(
        timestamp: UInt64,
        localID: UInt8 = 0
    ) throws -> RecordedTouchPrimitive {
        try RecordedTouchPrimitive(
            dispatchUptimeNanoseconds: timestamp,
            phase: .down,
            contacts: [.init(localID: localID, x: Double(timestamp), y: 20)]
        )
    }
}

private struct PublisherContact: Hashable {
    let publisherID: UUID
    let localID: UInt8
}

private struct Fixture {
    let udid: String
    let baseDirectory: URL

    init(udid: String, createBaseDirectory: Bool = true) throws {
        self.udid = "TEST-TOUCH-\(udid)-\(UUID().uuidString.prefix(8))"
        self.baseDirectory = URL(
            fileURLWithPath: "/tmp/sim-use-touch-stream-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        if createBaseDirectory {
            try FileManager.default.createDirectory(
                at: baseDirectory,
                withIntermediateDirectories: true
            )
        }
    }

    func listener(
        onInput: @escaping RecordedTouchStreamListener.InputHandler,
        now: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) throws -> RecordedTouchStreamListener {
        try RecordedTouchStreamListener(
            udid: udid,
            baseDirectory: baseDirectory,
            onInput: onInput,
            now: now
        )
    }

    func publisher(
        publisherID: UUID = UUID(),
        queueCapacity: Int = RecordedTouchStreamPublisher.defaultQueueCapacity,
        connector: RecordedTouchStreamConnector = .system
    ) -> RecordedTouchStreamPublisher {
        RecordedTouchStreamPublisher(
            udid: udid,
            baseDirectory: baseDirectory,
            publisherID: publisherID,
            queueCapacity: queueCapacity,
            connector: connector
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: baseDirectory)
    }
}

/// Holds the publisher's only transport seam at connect so queue overflow can
/// be proven without sleeps. `condition` owns both mutable flags.
private final class ConnectGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    func connect() -> RecordedTouchStreamConnector.Result {
        condition.lock()
        started = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
        return .noListener
    }

    func waitUntilStarted(timeout: TimeInterval = 2) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !started {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

/// The test gives this immutable reference to one worker and does not close it
/// until the worker's condition-backed completion has fired.
private final class PublisherBox: @unchecked Sendable {
    let value: RecordedTouchStreamPublisher
    init(_ value: RecordedTouchStreamPublisher) { self.value = value }
}

/// `condition` owns the worker's start, result, and completion observations.
private final class FlushProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var storedResult: RecordedTouchStreamDeliveryResult?

    var isFinished: Bool {
        condition.withLock { storedResult != nil }
    }

    var result: RecordedTouchStreamDeliveryResult? {
        condition.withLock { storedResult }
    }

    func markStarted() {
        condition.withLock {
            started = true
            condition.broadcast()
        }
    }

    func finish(_ result: RecordedTouchStreamDeliveryResult) {
        condition.withLock {
            storedResult = result
            condition.broadcast()
        }
    }

    func waitUntilStarted(timeout: TimeInterval = 2) -> Bool {
        wait(timeout: timeout) { started }
    }

    func waitUntilFinished(timeout: TimeInterval = 2) -> Bool {
        wait(timeout: timeout) { storedResult != nil }
    }

    private func wait(timeout: TimeInterval, until predicate: () -> Bool) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }
}

/// The condition owns both the callback-written array and completion wait;
/// listener callbacks never expose the mutable storage outside the lock.
private final class InputCollector: @unchecked Sendable {
    private let condition = NSCondition()
    private var storedValues: [RecordedTouchInput] = []

    var values: [RecordedTouchInput] {
        condition.lock()
        defer { condition.unlock() }
        return storedValues
    }

    func append(_ input: RecordedTouchInput) {
        condition.lock()
        storedValues.append(input)
        condition.broadcast()
        condition.unlock()
    }

    func waitForCount(_ count: Int, timeout: TimeInterval = 2) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while storedValues.count < count {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }
}
