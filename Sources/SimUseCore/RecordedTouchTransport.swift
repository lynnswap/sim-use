// SPDX-License-Identifier: Apache-2.0
import Darwin
import Dispatch
import Foundation

/// Canonical per-UDID endpoint for the recording touch-indicator channel.
/// The channel deliberately shares the daemon's validated 0700 base directory,
/// but uses its own socket and ownership file rather than the command FIFO.
package struct RecordedTouchTransportPaths: Sendable {
    package let udid: String
    package let baseDirectory: URL

    package init(udid: String, baseDirectory: URL? = nil) {
        self.udid = udid
        self.baseDirectory = baseDirectory ?? DaemonPaths.defaultBaseDirectory
    }

    package var socketURL: URL {
        baseDirectory.appendingPathComponent("\(udid).touch.sock", isDirectory: false)
    }

    package var pidfileURL: URL {
        baseDirectory.appendingPathComponent("\(udid).touch.pid", isDirectory: false)
    }

    package func ensureSecureBaseDirectory() throws {
        try DaemonPaths(udid: udid, baseDirectory: baseDirectory).ensureBaseDirectory()
    }
}

package struct RecordedTouchTransportDiagnostic: Equatable, Sendable, CustomStringConvertible {
    package enum Kind: String, Equatable, Sendable {
        case encodingFailed = "encoding_failed"
        case endpointInspectionFailed = "endpoint_inspection_failed"
        case socketFailed = "socket_failed"
        case deliveryFailed = "delivery_failed"
        case malformedPayload = "malformed_payload"
        case versionMismatch = "version_mismatch"
        case udidMismatch = "udid_mismatch"
        case unorderedSamples = "unordered_samples"
        case receiveFailed = "receive_failed"
        case datagramTooLarge = "datagram_too_large"
    }

    package let kind: Kind
    package let message: String

    package init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    package var description: String {
        "Recorded touch transport \(kind.rawValue): \(message)"
    }
}

package enum RecordedTouchPublishResult: Equatable, Sendable {
    case delivered
    case noListener
    case failed(RecordedTouchTransportDiagnostic)
}

/// Best-effort publisher used by the HID dispatch path.
///
/// Publishing performs one datagram send and never throws or retries. A missing
/// listener is normal; all other failures are returned for diagnostic logging
/// without changing the HID operation's result.
package struct RecordedTouchEventPublisher: Sendable {
    package let paths: RecordedTouchTransportPaths

    package init(udid: String, baseDirectory: URL? = nil) {
        self.paths = RecordedTouchTransportPaths(udid: udid, baseDirectory: baseDirectory)
    }

    package func publish(_ event: RecordedTouchEvent) -> RecordedTouchPublishResult {
        if let diagnostic = RecordedTouchEventValidator.validate(event, expectedUDID: paths.udid) {
            return .failed(diagnostic)
        }

        var endpointStat = stat()
        guard lstat(paths.baseDirectory.path, &endpointStat) == 0 else {
            if errno == ENOENT { return .noListener }
            return .failed(Self.syscallDiagnostic(kind: .endpointInspectionFailed, operation: "lstat base directory"))
        }

        do {
            try DaemonPaths.validateBaseDirectory(at: paths.baseDirectory)
        } catch {
            return .failed(.init(
                kind: .endpointInspectionFailed,
                message: "Cannot trust \(paths.baseDirectory.path): \(String(describing: error))"
            ))
        }

        guard lstat(paths.socketURL.path, &endpointStat) == 0 else {
            if errno == ENOENT { return .noListener }
            return .failed(Self.syscallDiagnostic(kind: .endpointInspectionFailed, operation: "lstat endpoint"))
        }

        let payloads: [Data]
        do {
            payloads = try Self.encodedPayloads(for: event)
        } catch {
            let kind: RecordedTouchTransportDiagnostic.Kind = error is OversizedRecordedTouchSample
                ? .datagramTooLarge
                : .encodingFailed
            return .failed(.init(kind: kind, message: error.localizedDescription))
        }

        do {
            try RecordedTouchUnixDatagram.ensurePathFits(paths.socketURL.path)
        } catch {
            return .failed(.init(kind: .socketFailed, message: error.localizedDescription))
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            return .failed(Self.syscallDiagnostic(kind: .socketFailed, operation: "socket"))
        }
        defer { Darwin.close(fd) }

        var sendBufferBytes: Int32 = RecordedTouchUnixDatagram.socketBufferBytes
        guard setsockopt(
            fd,
            SOL_SOCKET,
            SO_SNDBUF,
            &sendBufferBytes,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            return .failed(Self.syscallDiagnostic(
                kind: .socketFailed,
                operation: "set send buffer"
            ))
        }

        let statusFlags = fcntl(fd, F_GETFL, 0)
        guard statusFlags >= 0,
              fcntl(fd, F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
            return .failed(Self.syscallDiagnostic(
                kind: .socketFailed,
                operation: "set nonblocking sender"
            ))
        }

        for payload in payloads {
            var address = RecordedTouchUnixDatagram.address(for: paths.socketURL.path)
            let sent = payload.withUnsafeBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return withUnsafePointer(to: &address) { addressPointer in
                    addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                        Darwin.sendto(
                            fd,
                            baseAddress,
                            bytes.count,
                            0,
                            socketAddress,
                            socklen_t(MemoryLayout<sockaddr_un>.size)
                        )
                    }
                }
            }

            guard sent == payload.count else {
                if sent < 0 {
                    return .failed(Self.syscallDiagnostic(kind: .deliveryFailed, operation: "sendto"))
                }
                return .failed(.init(
                    kind: .deliveryFailed,
                    message: "sendto wrote \(sent) of \(payload.count) bytes"
                ))
            }
        }
        return .delivered
    }

    /// macOS commonly caps local datagrams at 2048 bytes. Keep each JSON
    /// payload below that limit and preserve the original event ID/timeline
    /// across chunks; Unix datagrams from one socket retain send order.
    private static func encodedPayloads(for event: RecordedTouchEvent) throws -> [Data] {
        let encoder = JSONEncoder()
        let whole = try encoder.encode(event)
        guard whole.count > RecordedTouchUnixDatagram.safePayloadBytes else {
            return [whole]
        }

        var payloads: [Data] = []
        var chunkSamples: [RecordedTouchSample] = []
        for sample in event.samples {
            let candidate = event.withSamples(chunkSamples + [sample])
            let candidatePayload = try encoder.encode(candidate)
            if candidatePayload.count <= RecordedTouchUnixDatagram.safePayloadBytes {
                chunkSamples.append(sample)
                continue
            }

            guard !chunkSamples.isEmpty else {
                throw OversizedRecordedTouchSample(
                    encodedBytes: candidatePayload.count,
                    limit: RecordedTouchUnixDatagram.safePayloadBytes
                )
            }
            payloads.append(try encoder.encode(event.withSamples(chunkSamples)))
            chunkSamples = [sample]

            let singlePayload = try encoder.encode(event.withSamples(chunkSamples))
            guard singlePayload.count <= RecordedTouchUnixDatagram.safePayloadBytes else {
                throw OversizedRecordedTouchSample(
                    encodedBytes: singlePayload.count,
                    limit: RecordedTouchUnixDatagram.safePayloadBytes
                )
            }
        }

        if !chunkSamples.isEmpty {
            payloads.append(try encoder.encode(event.withSamples(chunkSamples)))
        }
        return payloads
    }

    private static func syscallDiagnostic(
        kind: RecordedTouchTransportDiagnostic.Kind,
        operation: String
    ) -> RecordedTouchTransportDiagnostic {
        let errorNumber = errno
        return .init(
            kind: kind,
            message: "\(operation) failed (errno=\(errorNumber)): \(String(cString: strerror(errorNumber)))"
        )
    }
}

private extension RecordedTouchEvent {
    func withSamples(_ samples: [RecordedTouchSample]) -> RecordedTouchEvent {
        RecordedTouchEvent(
            version: version,
            udid: udid,
            eventID: eventID,
            dispatchUptimeNanoseconds: dispatchUptimeNanoseconds,
            samples: samples
        )
    }
}

private struct OversizedRecordedTouchSample: Error, LocalizedError {
    let encodedBytes: Int
    let limit: Int

    var errorDescription: String? {
        "One recorded-touch sample encodes to \(encodedBytes) bytes, exceeding the safe local datagram limit of \(limit) bytes."
    }
}

package enum RecordedTouchListenerError: Error, Equatable, LocalizedError {
    case listenerAlreadyActive(udid: String, pid: pid_t?)
    case ownerCannotBeVerified(path: String)
    case endpointHasNoOwner(path: String)
    case invalidOwnershipFile(path: String)
    case pathTooLong(path: String, limit: Int)
    case syscallFailed(operation: String, errno: Int32, message: String)

    package var errorDescription: String? {
        switch self {
        case .listenerAlreadyActive(let udid, let pid):
            let owner = pid.map { " (pid \($0))" } ?? ""
            return "A touch-indicator recording is already active for \(udid)\(owner)."
        case .ownerCannotBeVerified(let path):
            return "Cannot verify the previous touch-indicator owner in \(path); refusing to replace its endpoint."
        case .endpointHasNoOwner(let path):
            return "Touch-indicator endpoint \(path) exists without a verifiable owner; remove the stale endpoint and retry."
        case .invalidOwnershipFile(let path):
            return "Touch-indicator ownership path \(path) is not a regular file owned by the current user."
        case .pathTooLong(let path, let limit):
            return "Touch-indicator socket path is \(path.utf8.count) bytes but the AF_UNIX limit is \(limit): \(path)"
        case .syscallFailed(let operation, let errorNumber, let message):
            return "Touch-indicator listener \(operation) failed (errno=\(errorNumber)): \(message)"
        }
    }
}

/// Exclusive recorder-side owner of one per-UDID Unix datagram endpoint.
///
/// The listener starts during initialization. `close()` synchronously stops
/// intake, waits for any callback already running on the private serial queue,
/// closes the socket, and removes only the socket/PID path inodes created or
/// claimed by this instance. `deinit` is a synchronous cleanup backstop.
package final class RecordedTouchEventListener {
    package typealias EventHandler = @Sendable (RecordedTouchEvent) -> Void
    package typealias DiagnosticHandler = @Sendable (RecordedTouchTransportDiagnostic) -> Void

    package let paths: RecordedTouchTransportPaths

    private let state: IntakeState
    private let source: DispatchSourceRead
    private let intakeQueue: DispatchQueue
    private let intakeQueueKey = DispatchSpecificKey<UInt8>()
    private let closeCondition = NSCondition()
    private var closeState = CloseState.open

    package init(
        udid: String,
        baseDirectory: URL? = nil,
        onEvent: @escaping EventHandler,
        onDiagnostic: DiagnosticHandler? = nil
    ) throws {
        let paths = RecordedTouchTransportPaths(udid: udid, baseDirectory: baseDirectory)
        let state = try IntakeState(
            paths: paths,
            eventHandler: onEvent,
            diagnosticHandler: onDiagnostic
        )
        let queue = DispatchQueue(label: "com.lycorp.sim-use.recorded-touch.\(udid)")
        queue.setSpecific(key: intakeQueueKey, value: 1)
        let source = DispatchSource.makeReadSource(fileDescriptor: state.socketFD, queue: queue)

        self.paths = paths
        self.state = state
        self.intakeQueue = queue
        self.source = source

        source.setEventHandler { [state] in
            state.drainDatagrams()
        }
        source.activate()
    }

    package func close() {
        closeCondition.lock()
        switch closeState {
        case .closed:
            closeCondition.unlock()
            return
        case .closing:
            // A callback already on `intakeQueue` must return so the
            // caller performing queue.sync can finish the primary close.
            if DispatchQueue.getSpecific(key: intakeQueueKey) != nil {
                closeCondition.unlock()
                return
            }
            while closeState != .closed {
                closeCondition.wait()
            }
            closeCondition.unlock()
            return
        case .open:
            closeState = .closing
            closeCondition.unlock()
        }

        source.cancel()
        if DispatchQueue.getSpecific(key: intakeQueueKey) == nil {
            intakeQueue.sync {
                state.closeResources()
            }
        } else {
            state.closeResources()
        }

        closeCondition.lock()
        closeState = .closed
        closeCondition.broadcast()
        closeCondition.unlock()
    }

    deinit {
        close()
    }

    private enum CloseState {
        case open
        case closing
        case closed
    }
}

// GCD invokes this reference from its private serial queue while `close()` may
// be called by the listener owner. Every mutable resource field is protected by
// `lock`; callbacks receive immutable Sendable values only. The synchronized
// type therefore owns the full cross-thread access contract required by this
// narrow `@unchecked Sendable` bridge to DispatchSource.
private final class IntakeState: @unchecked Sendable {
    fileprivate let socketFD: Int32

    private let paths: RecordedTouchTransportPaths
    private let pidfileFD: Int32
    private let socketIdentity: FileIdentity
    private let pidfileIdentity: FileIdentity
    private let eventHandler: RecordedTouchEventListener.EventHandler
    private let diagnosticHandler: RecordedTouchEventListener.DiagnosticHandler?
    private let lock = NSLock()
    private var resourcesClosed = false

    init(
        paths: RecordedTouchTransportPaths,
        eventHandler: @escaping RecordedTouchEventListener.EventHandler,
        diagnosticHandler: RecordedTouchEventListener.DiagnosticHandler?
    ) throws {
        let claimedOwnership = try RecordedTouchOwnership.claim(paths: paths)
        do {
            let socket = try RecordedTouchUnixDatagram.bind(path: paths.socketURL.path)

            self.paths = paths
            self.pidfileFD = claimedOwnership.fd
            self.pidfileIdentity = claimedOwnership.identity
            self.socketFD = socket.fd
            self.socketIdentity = socket.identity
            self.eventHandler = eventHandler
            self.diagnosticHandler = diagnosticHandler
        } catch {
            claimedOwnership.releaseRemovingOwnedPath()
            throw error
        }
    }

    func drainDatagrams() {
        var buffer = [UInt8](repeating: 0, count: RecordedTouchUnixDatagram.maximumDatagramBytes)
        while true {
            lock.lock()
            let closed = resourcesClosed
            lock.unlock()
            if closed { return }

            let received = buffer.withUnsafeMutableBytes { bytes -> Int in
                Darwin.recv(socketFD, bytes.baseAddress, bytes.count, 0)
            }

            if received < 0 {
                let errorNumber = errno
                if errorNumber == EINTR { continue }
                if errorNumber == EAGAIN || errorNumber == EWOULDBLOCK || errorNumber == EBADF { return }
                emit(.init(
                    kind: .receiveFailed,
                    message: "recv failed (errno=\(errorNumber)): \(String(cString: strerror(errorNumber)))"
                ))
                return
            }

            if received == buffer.count {
                emit(.init(
                    kind: .datagramTooLarge,
                    message: "Datagram reached the \(buffer.count)-byte receive limit and was discarded."
                ))
                continue
            }

            let data = Data(buffer.prefix(received))
            let event: RecordedTouchEvent
            do {
                event = try JSONDecoder().decode(RecordedTouchEvent.self, from: data)
            } catch {
                emit(.init(kind: .malformedPayload, message: error.localizedDescription))
                continue
            }

            if let diagnostic = RecordedTouchEventValidator.validate(event, expectedUDID: paths.udid) {
                emit(diagnostic)
                continue
            }
            eventHandler(event)
        }
    }

    func closeResources() {
        lock.lock()
        guard !resourcesClosed else {
            lock.unlock()
            return
        }
        resourcesClosed = true
        lock.unlock()

        RecordedTouchOwnership.removePathIfOwned(paths.socketURL, identity: socketIdentity)
        Darwin.close(socketFD)
        RecordedTouchOwnership.removePathIfOwned(paths.pidfileURL, identity: pidfileIdentity)
        _ = flock(pidfileFD, LOCK_UN)
        Darwin.close(pidfileFD)
    }

    private func emit(_ diagnostic: RecordedTouchTransportDiagnostic) {
        diagnosticHandler?(diagnostic)
    }
}

private enum RecordedTouchEventValidator {
    static func validate(
        _ event: RecordedTouchEvent,
        expectedUDID: String
    ) -> RecordedTouchTransportDiagnostic? {
        guard event.version == RecordedTouchEvent.currentVersion else {
            return .init(
                kind: .versionMismatch,
                message: "Got version \(event.version), expected \(RecordedTouchEvent.currentVersion)."
            )
        }
        guard event.udid == expectedUDID else {
            return .init(
                kind: .udidMismatch,
                message: "Got UDID \(event.udid), expected \(expectedUDID)."
            )
        }
        for (earlier, later) in zip(event.samples, event.samples.dropFirst())
        where earlier.relativeNanoseconds > later.relativeNanoseconds {
            return .init(
                kind: .unorderedSamples,
                message: "Sample offsets must be monotonically nondecreasing."
            )
        }
        return nil
    }
}

private struct ClaimedOwnership {
    let fd: Int32
    let identity: FileIdentity
    let path: URL

    func releaseRemovingOwnedPath() {
        RecordedTouchOwnership.removePathIfOwned(path, identity: identity)
        _ = flock(fd, LOCK_UN)
        Darwin.close(fd)
    }
}

private enum RecordedTouchOwnership {
    static func claim(paths: RecordedTouchTransportPaths) throws -> ClaimedOwnership {
        try paths.ensureSecureBaseDirectory()

        let pidPath = paths.pidfileURL.path
        let createFlags = O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
        var newlyCreated = false
        var fd = Darwin.open(pidPath, createFlags, mode_t(0o600))
        if fd >= 0 {
            newlyCreated = true
        } else if errno == EEXIST {
            fd = Darwin.open(pidPath, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else {
            throw syscallError(operation: "open ownership file")
        }

        var shouldClose = true
        var removeOwnershipPathOnFailure = newlyCreated
        defer {
            if shouldClose {
                if removeOwnershipPathOnFailure {
                    removePathIfDescriptorOwned(paths.pidfileURL, fd: fd)
                }
                _ = flock(fd, LOCK_UN)
                Darwin.close(fd)
            }
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let errorNumber = errno
            let ownerPID = readPID(fd: fd)
            if errorNumber == EWOULDBLOCK {
                throw RecordedTouchListenerError.listenerAlreadyActive(udid: paths.udid, pid: ownerPID)
            }
            throw syscallError(operation: "lock ownership file", errorNumber: errorNumber)
        }

        var fileStat = stat()
        guard fstat(fd, &fileStat) == 0 else {
            throw syscallError(operation: "fstat ownership file")
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG, fileStat.st_uid == getuid() else {
            throw RecordedTouchListenerError.invalidOwnershipFile(path: pidPath)
        }
        guard fchmod(fd, 0o600) == 0 else {
            throw syscallError(operation: "chmod ownership file")
        }

        if newlyCreated {
            var socketStat = stat()
            if lstat(paths.socketURL.path, &socketStat) == 0 {
                throw RecordedTouchListenerError.endpointHasNoOwner(path: paths.socketURL.path)
            }
            if errno != ENOENT {
                throw syscallError(operation: "lstat endpoint")
            }
        } else {
            guard let previousPID = readPID(fd: fd) else {
                throw RecordedTouchListenerError.ownerCannotBeVerified(path: pidPath)
            }
            guard previousPID > 0 else {
                throw RecordedTouchListenerError.ownerCannotBeVerified(path: pidPath)
            }
            guard isProcessProvenDead(previousPID) else {
                throw RecordedTouchListenerError.listenerAlreadyActive(udid: paths.udid, pid: previousPID)
            }
            if unlink(paths.socketURL.path) != 0, errno != ENOENT {
                throw syscallError(operation: "remove stale endpoint")
            }
            removeOwnershipPathOnFailure = true
        }

        try writePID(getpid(), fd: fd)
        let identity = FileIdentity(device: fileStat.st_dev, inode: fileStat.st_ino)
        shouldClose = false
        return ClaimedOwnership(fd: fd, identity: identity, path: paths.pidfileURL)
    }

    static func removePathIfOwned(_ url: URL, identity: FileIdentity) {
        guard let currentIdentity = try? FileIdentity(path: url.path, operation: "lstat owned path"),
              currentIdentity == identity else {
            return
        }
        _ = unlink(url.path)
    }

    private static func removePathIfDescriptorOwned(_ url: URL, fd: Int32) {
        var descriptorStat = stat()
        guard fstat(fd, &descriptorStat) == 0 else { return }
        removePathIfOwned(
            url,
            identity: .init(device: descriptorStat.st_dev, inode: descriptorStat.st_ino)
        )
    }

    private static func readPID(fd: Int32) -> pid_t? {
        guard lseek(fd, 0, SEEK_SET) >= 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 64)
        let count = bytes.withUnsafeMutableBytes { buffer in
            Darwin.read(fd, buffer.baseAddress, buffer.count)
        }
        guard count > 0, count < bytes.count,
              let text = String(bytes: bytes.prefix(count), encoding: .utf8) else {
            return nil
        }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func writePID(_ pid: pid_t, fd: Int32) throws {
        guard ftruncate(fd, 0) == 0 else {
            throw syscallError(operation: "truncate ownership file")
        }
        guard lseek(fd, 0, SEEK_SET) >= 0 else {
            throw syscallError(operation: "seek ownership file")
        }
        let data = Data("\(pid)\n".utf8)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.write(fd, baseAddress.advanced(by: offset), data.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw syscallError(operation: "write ownership file")
            }
            offset += written
        }
    }

    /// Reclamation requires positive proof that the recorded process no
    /// longer exists. Permission and other probe failures are not evidence of
    /// death and therefore leave the endpoint untouched.
    private static func isProcessProvenDead(_ pid: pid_t) -> Bool {
        guard Darwin.kill(pid, 0) != 0 else { return false }
        return errno == ESRCH
    }

    private static func syscallError(
        operation: String,
        errorNumber: Int32 = errno
    ) -> RecordedTouchListenerError {
        .syscallFailed(
            operation: operation,
            errno: errorNumber,
            message: String(cString: strerror(errorNumber))
        )
    }
}

private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init(device: dev_t, inode: ino_t) {
        self.device = device
        self.inode = inode
    }

    init(path: String, operation: String) throws {
        var fileStat = stat()
        guard lstat(path, &fileStat) == 0 else {
            let errorNumber = errno
            throw RecordedTouchListenerError.syscallFailed(
                operation: operation,
                errno: errorNumber,
                message: String(cString: strerror(errorNumber))
            )
        }
        self.init(device: fileStat.st_dev, inode: fileStat.st_ino)
    }
}

private enum RecordedTouchUnixDatagram {
    static let maximumDatagramBytes = 1024 * 1024
    static let safePayloadBytes = 1_800
    static let socketBufferBytes: Int32 = 1024 * 1024

    static func bind(path: String) throws -> BoundSocket {
        try ensurePathFits(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw syscallError(operation: "socket") }

        var shouldClose = true
        var boundIdentity: FileIdentity?
        defer {
            if shouldClose {
                Darwin.close(fd)
                if let boundIdentity {
                    RecordedTouchOwnership.removePathIfOwned(
                        URL(fileURLWithPath: path),
                        identity: boundIdentity
                    )
                }
            }
        }

        var receiveBufferBytes: Int32 = socketBufferBytes
        guard setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVBUF,
            &receiveBufferBytes,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw syscallError(operation: "set receive buffer")
        }

        var address = address(for: path)
        let bindResult = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { throw syscallError(operation: "bind") }
        let identity = try FileIdentity(path: path, operation: "lstat bound socket")
        boundIdentity = identity
        guard chmod(path, 0o600) == 0 else { throw syscallError(operation: "chmod socket") }

        let statusFlags = fcntl(fd, F_GETFL, 0)
        guard statusFlags >= 0, fcntl(fd, F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
            throw syscallError(operation: "set nonblocking socket")
        }
        let descriptorFlags = fcntl(fd, F_GETFD, 0)
        guard descriptorFlags >= 0, fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            throw syscallError(operation: "set close-on-exec socket")
        }

        shouldClose = false
        return BoundSocket(fd: fd, identity: identity)
    }

    static func ensurePathFits(_ path: String) throws {
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard path.utf8.count < capacity else {
            throw RecordedTouchListenerError.pathTooLong(path: path, limit: capacity)
        }
    }

    static func address(for path: String) -> sockaddr_un {
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
        return address
    }

    private static func syscallError(operation: String) -> RecordedTouchListenerError {
        let errorNumber = errno
        return .syscallFailed(
            operation: operation,
            errno: errorNumber,
            message: String(cString: strerror(errorNumber))
        )
    }

    struct BoundSocket {
        let fd: Int32
        let identity: FileIdentity
    }
}
