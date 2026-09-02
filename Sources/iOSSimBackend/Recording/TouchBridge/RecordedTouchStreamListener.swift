// SPDX-License-Identifier: Apache-2.0
import Darwin
import Dispatch
import Foundation
import SimUseCore

package enum RecordedTouchStreamListenerError: Error, LocalizedError, Equatable {
    case listenerAlreadyActive(udid: String)
    case invalidLockFile(path: String)

    package var errorDescription: String? {
        switch self {
        case .listenerAlreadyActive(let udid):
            "A touch-indicator recording is already active for \(udid)."
        case .invalidLockFile(let path):
            "Touch-indicator lock path is not a regular file owned by this user: \(path)"
        }
    }
}

/// Recorder-side owner of the exclusive per-UDID endpoint and all accepted
/// publisher connections.
package final class RecordedTouchStreamListener {
    package typealias InputHandler = @Sendable (RecordedTouchInput) -> Void
    package typealias DiagnosticHandler = @Sendable (String) -> Void

    package let paths: RecordedTouchStreamPaths

    private let intakeQueue: DispatchQueue
    private let intakeQueueKey = DispatchSpecificKey<UInt8>()
    private let state: ListenerState
    private let source: DispatchSourceRead
    private let closeLock = NSLock()
    private var closeRequested = false

    package init(
        udid: String,
        baseDirectory: URL? = nil,
        onInput: @escaping InputHandler,
        onDiagnostic: DiagnosticHandler? = nil,
        now: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) throws {
        let paths = RecordedTouchStreamPaths(udid: udid, baseDirectory: baseDirectory)
        let ownership = try EndpointOwnership.claim(paths: paths)
        let queue = DispatchQueue(label: "com.lycorp.sim-use.recorded-touch.listener.\(udid)")
        queue.setSpecific(key: intakeQueueKey, value: 1)
        let state = ListenerState(
            queue: queue,
            paths: paths,
            ownership: ownership,
            onInput: onInput,
            onDiagnostic: onDiagnostic,
            now: now
        )
        let source = DispatchSource.makeReadSource(
            fileDescriptor: ownership.listenerFD,
            queue: queue
        )

        self.paths = paths
        self.intakeQueue = queue
        self.state = state
        self.source = source

        source.setEventHandler { [state] in
            state.acceptPendingConnections()
        }
        source.activate()
    }

    /// Stops intake, closes every accepted session, emits its final close
    /// input, and removes only the endpoint resources owned by this listener.
    package func close() {
        let shouldCancel = closeLock.withLock {
            guard !closeRequested else { return false }
            closeRequested = true
            return true
        }
        if shouldCancel { source.cancel() }
        if DispatchQueue.getSpecific(key: intakeQueueKey) != nil {
            state.closeResources()
        } else {
            intakeQueue.sync { state.closeResources() }
        }
    }

    deinit {
        close()
    }
}

/// Mutable connection state is confined to `queue`; every mutating method
/// asserts that executor. Dispatch sources invoke this identity across a
/// `@Sendable` callback, which is the sole reason for the unchecked conformance.
private final class ListenerState: @unchecked Sendable {
    private final class Connection {
        let source: DispatchSourceRead
        var buffer = Data()
        var publisherID: UUID?

        init(source: DispatchSourceRead) {
            self.source = source
        }
    }

    private let queue: DispatchQueue
    private let paths: RecordedTouchStreamPaths
    private let ownership: EndpointOwnership
    private let onInput: RecordedTouchStreamListener.InputHandler
    private let onDiagnostic: RecordedTouchStreamListener.DiagnosticHandler?
    private let now: @Sendable () -> UInt64
    private var connections: [Int32: Connection] = [:]
    private var resourcesClosed = false

    init(
        queue: DispatchQueue,
        paths: RecordedTouchStreamPaths,
        ownership: EndpointOwnership,
        onInput: @escaping RecordedTouchStreamListener.InputHandler,
        onDiagnostic: RecordedTouchStreamListener.DiagnosticHandler?,
        now: @escaping @Sendable () -> UInt64
    ) {
        self.queue = queue
        self.paths = paths
        self.ownership = ownership
        self.onInput = onInput
        self.onDiagnostic = onDiagnostic
        self.now = now
    }

    func acceptPendingConnections() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !resourcesClosed else { return }
        while true {
            let fd = Darwin.accept(ownership.listenerFD, nil, nil)
            if fd < 0 {
                let errorNumber = errno
                if errorNumber == EINTR { continue }
                if errorNumber != EAGAIN && errorNumber != EWOULDBLOCK {
                    emit("accept failed (errno=\(errorNumber)): \(String(cString: strerror(errorNumber)))")
                }
                return
            }

            guard Self.configureAcceptedSocket(fd) else {
                let errorNumber = errno
                emit("accepted socket setup failed (errno=\(errorNumber)): \(String(cString: strerror(errorNumber)))")
                Darwin.close(fd)
                continue
            }

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let connection = Connection(source: source)
            connections[fd] = connection
            source.setEventHandler { [weak self] in
                self?.readAvailableBytes(from: fd)
            }
            source.activate()
        }
    }

    func closeResources() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !resourcesClosed else { return }
        resourcesClosed = true
        for fd in Array(connections.keys) {
            closeConnection(fd)
        }
        ownership.release(paths: paths)
    }

    private func readAvailableBytes(from fd: Int32) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !resourcesClosed, connections[fd] != nil else { return }
        var bytes = [UInt8](repeating: 0, count: 4 * 1024)
        while true {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress, buffer.count)
            }
            if count > 0 {
                guard let connection = connections[fd] else { return }
                connection.buffer.append(contentsOf: bytes.prefix(count))
                processFrames(for: fd)
                guard connections[fd] != nil else { return }
                continue
            }
            if count == 0 {
                closeConnection(fd)
                return
            }

            let errorNumber = errno
            if errorNumber == EINTR { continue }
            if errorNumber != EAGAIN && errorNumber != EWOULDBLOCK {
                emit("read failed (errno=\(errorNumber)): \(String(cString: strerror(errorNumber)))")
                closeConnection(fd)
            }
            return
        }
    }

    private func processFrames(for fd: Int32) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let connection = connections[fd] else { return }
        while let newline = connection.buffer.firstIndex(of: 0x0A) {
            let frame = Data(connection.buffer[..<newline])
            connection.buffer.removeSubrange(...newline)
            do {
                switch try RecordedTouchStreamWire.decode(frame) {
                case .hello(let publisherID):
                    guard connection.publisherID == nil else {
                        throw RecordedTouchStreamWireError.invalidMessageShape
                    }
                    connection.publisherID = publisherID
                case .update(let primitive):
                    guard let publisherID = connection.publisherID else {
                        throw RecordedTouchStreamWireError.invalidMessageShape
                    }
                    onInput(.update(publisherID: publisherID, primitive: primitive))
                    guard connections[fd] != nil else { return }
                }
            } catch {
                emit("discarded malformed stream frame: \(error.localizedDescription)")
                closeConnection(fd)
                return
            }
        }
        if connection.buffer.count >= RecordedTouchStreamWire.maximumFrameBytes {
            emit("discarded stream frame larger than \(RecordedTouchStreamWire.maximumFrameBytes) bytes")
            closeConnection(fd)
        }
    }

    private func closeConnection(_ fd: Int32) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let connection = connections.removeValue(forKey: fd) else { return }
        connection.source.cancel()
        Darwin.close(fd)
        if let publisherID = connection.publisherID {
            onInput(.publisherClosed(
                publisherID: publisherID,
                uptimeNanoseconds: now()
            ))
        }
    }

    private func emit(_ message: String) {
        onDiagnostic?(message)
    }

    private static func configureAcceptedSocket(_ fd: Int32) -> Bool {
        let statusFlags = fcntl(fd, F_GETFL, 0)
        guard statusFlags >= 0,
              fcntl(fd, F_SETFL, statusFlags | O_NONBLOCK) == 0 else { return false }
        let descriptorFlags = fcntl(fd, F_GETFD, 0)
        return descriptorFlags >= 0
            && fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
    }
}

private struct EndpointOwnership {
    let listenerFD: Int32
    let lockFD: Int32
    let socketIdentity: FileIdentity
    let lockIdentity: FileIdentity

    static func claim(paths: RecordedTouchStreamPaths) throws -> Self {
        try paths.ensureSecureChannelDirectory()
        let flags = O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW
        let lockFD = Darwin.open(paths.lockURL.path, flags, mode_t(0o600))
        guard lockFD >= 0 else { throw syscall("open lock file") }

        var acquiredLock = false
        var ownsLock = false
        defer {
            if !ownsLock {
                if acquiredLock { _ = flock(lockFD, LOCK_UN) }
                Darwin.close(lockFD)
            }
        }

        var lockStat = stat()
        guard fstat(lockFD, &lockStat) == 0 else { throw syscall("fstat lock file") }
        guard (lockStat.st_mode & S_IFMT) == S_IFREG, lockStat.st_uid == getuid() else {
            throw RecordedTouchStreamListenerError.invalidLockFile(path: paths.lockURL.path)
        }
        guard fchmod(lockFD, 0o600) == 0 else { throw syscall("chmod lock file") }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK {
                throw RecordedTouchStreamListenerError.listenerAlreadyActive(udid: paths.udid)
            }
            throw syscall("lock endpoint")
        }
        acquiredLock = true
        let lockIdentity = FileIdentity(device: lockStat.st_dev, inode: lockStat.st_ino)

        let listenerFD: Int32
        do {
            listenerFD = try DaemonSocket.listen(path: paths.socketURL.path)
        } catch {
            Self.removeIfOwned(paths.lockURL, identity: lockIdentity)
            throw error
        }

        do {
            let descriptorFlags = fcntl(listenerFD, F_GETFD, 0)
            guard descriptorFlags >= 0,
                  fcntl(listenerFD, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
                throw syscall("set close-on-exec listener")
            }
            let socketIdentity = try FileIdentity(path: paths.socketURL.path)
            ownsLock = true
            return Self(
                listenerFD: listenerFD,
                lockFD: lockFD,
                socketIdentity: socketIdentity,
                lockIdentity: lockIdentity
            )
        } catch {
            Darwin.close(listenerFD)
            _ = unlink(paths.socketURL.path)
            Self.removeIfOwned(paths.lockURL, identity: lockIdentity)
            throw error
        }
    }

    func release(paths: RecordedTouchStreamPaths) {
        Self.removeIfOwned(paths.socketURL, identity: socketIdentity)
        Darwin.close(listenerFD)
        Self.removeIfOwned(paths.lockURL, identity: lockIdentity)
        _ = flock(lockFD, LOCK_UN)
        Darwin.close(lockFD)
    }

    private static func removeIfOwned(_ url: URL, identity: FileIdentity) {
        guard let current = try? FileIdentity(path: url.path), current == identity else { return }
        _ = unlink(url.path)
    }

    private static func syscall(_ operation: String) -> DaemonSocketError {
        DaemonSocketError(op: operation, errno: errno)
    }
}

private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init(device: dev_t, inode: ino_t) {
        self.device = device
        self.inode = inode
    }

    init(path: String) throws {
        var fileStat = stat()
        guard lstat(path, &fileStat) == 0 else {
            throw DaemonSocketError(op: "lstat owned endpoint", errno: errno)
        }
        self.init(device: fileStat.st_dev, inode: fileStat.st_ino)
    }
}
