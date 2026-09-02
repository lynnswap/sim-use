// SPDX-License-Identifier: Apache-2.0
import Darwin
import Dispatch
import Foundation
import SimUseCore

package enum RecordedTouchStreamPublisherCloseReason: Equatable, Sendable {
    case explicit
    case queueOverflow(capacity: Int)
    case connectionFailed(String)
    case encodingFailed(String)
    case writeFailed(errorNumber: Int32)
}

package enum RecordedTouchStreamEnqueueResult: Equatable, Sendable {
    case enqueued
    case closed(RecordedTouchStreamPublisherCloseReason)
}

package enum RecordedTouchStreamDeliveryResult: Equatable, Sendable {
    case delivered
    case noListener
    case closed(RecordedTouchStreamPublisherCloseReason)
}

/// Owns one publisher ID, bounded outbound queue, and ordered connection.
/// `enqueue` only mutates memory and schedules one background drain;
/// connection setup, encoding, and writes happen on `ioQueue`.
package final class RecordedTouchStreamPublisher {
    package static let defaultQueueCapacity = 512

    private let state: PublisherState

    package init(
        udid: String,
        baseDirectory: URL? = nil,
        publisherID: UUID = UUID(),
        queueCapacity: Int = defaultQueueCapacity,
        connector: RecordedTouchStreamConnector = .system
    ) {
        precondition(queueCapacity > 0, "RecordedTouchStreamPublisher owns a positive bounded queue")
        let paths = RecordedTouchStreamPaths(udid: udid, baseDirectory: baseDirectory)
        self.state = PublisherState(
            publisherID: publisherID,
            socketPath: paths.socketURL.path,
            queueCapacity: queueCapacity,
            connector: connector
        )
    }

    @discardableResult
    package func enqueue(_ primitive: RecordedTouchPrimitive) -> RecordedTouchStreamEnqueueResult {
        state.enqueue(primitive)
    }

    @discardableResult
    package func flush() -> RecordedTouchStreamDeliveryResult { state.flush() }

    @discardableResult
    package func close() -> RecordedTouchStreamPublisherCloseReason { state.close() }

    deinit { _ = state.close() }
}

/// `lock` protects lifecycle, pending values, and the single-drain flag. The
/// descriptor and delivery outcome are confined to `ioQueue`, with every
/// access guarded by a dispatch precondition. This is the complete
/// synchronization invariant behind the GCD callback capture.
private final class PublisherState: @unchecked Sendable {
    private enum Lifecycle {
        case open
        case closing(RecordedTouchStreamPublisherCloseReason)
        case closed(RecordedTouchStreamPublisherCloseReason)
    }

    private let publisherID: UUID
    private let socketPath: String
    private let queueCapacity: Int
    private let connector: RecordedTouchStreamConnector
    private let ioQueue: DispatchQueue
    private let ioQueueKey = DispatchSpecificKey<UInt8>()
    private let lock = NSLock()
    private var lifecycle = Lifecycle.open
    private var pending: [RecordedTouchPrimitive] = []
    private var drainScheduled = false
    private var socketFD: Int32?
    private var unreportedDeliveryResult = RecordedTouchStreamDeliveryResult.delivered

    init(
        publisherID: UUID,
        socketPath: String,
        queueCapacity: Int,
        connector: RecordedTouchStreamConnector
    ) {
        self.publisherID = publisherID
        self.socketPath = socketPath
        self.queueCapacity = queueCapacity
        self.connector = connector
        self.ioQueue = DispatchQueue(
            label: "com.lycorp.sim-use.recorded-touch.publisher.\(publisherID.uuidString)"
        )
        ioQueue.setSpecific(key: ioQueueKey, value: 1)
    }

    func enqueue(_ primitive: RecordedTouchPrimitive) -> RecordedTouchStreamEnqueueResult {
        let outcome = lock.withLock { () -> (RecordedTouchStreamPublisherCloseReason?, Bool) in
            switch lifecycle {
            case .open where pending.count < queueCapacity:
                pending.append(primitive)
                let shouldSchedule = !drainScheduled
                drainScheduled = true
                return (nil, shouldSchedule)
            case .open:
                let reason = RecordedTouchStreamPublisherCloseReason.queueOverflow(
                    capacity: queueCapacity
                )
                lifecycle = .closing(reason)
                let shouldSchedule = !drainScheduled
                drainScheduled = true
                return (reason, shouldSchedule)
            case .closing(let reason), .closed(let reason):
                return (reason, false)
            }
        }
        if outcome.1 {
            ioQueue.async { [self] in drainPendingOnIOQueue() }
        }
        guard let terminalReason = outcome.0 else { return .enqueued }
        return .closed(terminalReason)
    }

    func flush() -> RecordedTouchStreamDeliveryResult {
        onIOQueue {
            drainPendingOnIOQueue()
            return consumeDeliveryResultOnIOQueue()
        }
    }

    func close() -> RecordedTouchStreamPublisherCloseReason {
        let initialReason = lock.withLock { () -> RecordedTouchStreamPublisherCloseReason in
            switch lifecycle {
            case .open:
                lifecycle = .closing(.explicit)
                return .explicit
            case .closing(let reason), .closed(let reason):
                return reason
            }
        }
        return onIOQueue {
            drainPendingOnIOQueue()
            return terminateOnIOQueue(initialReason)
        }
    }

    private func drainPendingOnIOQueue() {
        dispatchPrecondition(condition: .onQueue(ioQueue))
        while true {
            let next = lock.withLock { () -> Batch in
                switch lifecycle {
                case .open where !pending.isEmpty:
                    defer { pending.removeAll(keepingCapacity: true) }
                    return .primitives(pending)
                case .closing(.explicit) where !pending.isEmpty:
                    defer { pending.removeAll(keepingCapacity: false) }
                    return .primitives(pending)
                case .open, .closing(.explicit):
                    drainScheduled = false
                    return .empty
                case .closing(let reason), .closed(let reason):
                    drainScheduled = false
                    return .closed(reason)
                }
            }
            switch next {
            case .empty:
                return
            case .closed(let reason):
                recordDeliveryResultOnIOQueue(.closed(terminateOnIOQueue(reason)))
                return
            case .primitives(let batch):
                let result = deliverOnIOQueue(batch)
                recordDeliveryResultOnIOQueue(result)
                if case .closed = result { return }
            }
        }
    }

    private func deliverOnIOQueue(
        _ batch: [RecordedTouchPrimitive]
    ) -> RecordedTouchStreamDeliveryResult {
        switch connectIfNeededOnIOQueue() {
        case .delivered: break
        case .noListener: return .noListener
        case .closed(let reason): return .closed(reason)
        }
        guard let socketFD else {
            return failOnIOQueue(.connectionFailed("Connected stream has no descriptor."))
        }
        do {
            for primitive in batch {
                let frame = try RecordedTouchStreamWire.encode(.update(primitive))
                let write = DaemonSocket.writeAll(fd: socketFD, data: frame)
                guard write.ok else {
                    return failOnIOQueue(.writeFailed(errorNumber: write.lastErrno))
                }
            }
            return .delivered
        } catch {
            return failOnIOQueue(.encodingFailed(error.localizedDescription))
        }
    }

    private func recordDeliveryResultOnIOQueue(_ result: RecordedTouchStreamDeliveryResult) {
        dispatchPrecondition(condition: .onQueue(ioQueue))
        switch (unreportedDeliveryResult, result) {
        case (_, .closed):
            unreportedDeliveryResult = result
        case (.delivered, .noListener):
            unreportedDeliveryResult = .noListener
        case (.delivered, .delivered), (.noListener, .delivered), (.noListener, .noListener),
             (.closed, .delivered), (.closed, .noListener):
            break
        }
    }

    private func consumeDeliveryResultOnIOQueue() -> RecordedTouchStreamDeliveryResult {
        dispatchPrecondition(condition: .onQueue(ioQueue))
        let result = unreportedDeliveryResult
        if case .closed = result { return result }
        unreportedDeliveryResult = .delivered
        return result
    }

    private func connectIfNeededOnIOQueue() -> RecordedTouchStreamDeliveryResult {
        dispatchPrecondition(condition: .onQueue(ioQueue))
        if socketFD != nil { return .delivered }

        let fd: Int32
        switch connector.connect(path: socketPath) {
        case .connected(let connectedFD):
            fd = connectedFD
        case .noListener:
            return .noListener
        case .failed(let message):
            return failOnIOQueue(.connectionFailed(message))
        }

        guard Self.configureConnectedSocket(fd) else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            return failOnIOQueue(.connectionFailed(message))
        }
        socketFD = fd
        do {
            let hello = try RecordedTouchStreamWire.encode(.hello(publisherID: publisherID))
            let write = DaemonSocket.writeAll(fd: fd, data: hello)
            guard write.ok else {
                return failOnIOQueue(.writeFailed(errorNumber: write.lastErrno))
            }
            return .delivered
        } catch {
            return failOnIOQueue(.encodingFailed(error.localizedDescription))
        }
    }

    private func failOnIOQueue(
        _ reason: RecordedTouchStreamPublisherCloseReason
    ) -> RecordedTouchStreamDeliveryResult {
        .closed(terminateOnIOQueue(reason))
    }

    private func terminateOnIOQueue(
        _ reason: RecordedTouchStreamPublisherCloseReason
    ) -> RecordedTouchStreamPublisherCloseReason {
        dispatchPrecondition(condition: .onQueue(ioQueue))
        if let socketFD {
            Darwin.close(socketFD)
            self.socketFD = nil
        }
        return lock.withLock {
            pending.removeAll(keepingCapacity: false)
            drainScheduled = false
            if case .closed(let existing) = lifecycle { return existing }
            lifecycle = .closed(reason)
            return reason
        }
    }

    private func onIOQueue<Result>(_ body: () -> Result) -> Result {
        if DispatchQueue.getSpecific(key: ioQueueKey) != nil { return body() }
        return ioQueue.sync(execute: body)
    }

    private static func configureConnectedSocket(_ fd: Int32) -> Bool {
        RecordedTouchStreamSocket.configurePublisherFD(fd)
    }

    private enum Batch {
        case empty
        case primitives([RecordedTouchPrimitive])
        case closed(RecordedTouchStreamPublisherCloseReason)
    }
}

enum RecordedTouchStreamSocket {
    static func configurePublisherFD(_ fd: Int32) -> Bool {
        var noSigPipe: Int32 = 1
        guard setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else { return false }
        let statusFlags = fcntl(fd, F_GETFL, 0)
        guard statusFlags >= 0,
              fcntl(fd, F_SETFL, statusFlags | O_NONBLOCK) == 0 else { return false }
        let descriptorFlags = fcntl(fd, F_GETFD, 0)
        return descriptorFlags >= 0
            && fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
    }
}
