// SPDX-License-Identifier: Apache-2.0
import Darwin
import Dispatch
import Foundation

/// Identifies one listener ownership-file generation. Recovery data is scoped
/// to this value so a late publisher from an old recording cannot mutate a new
/// recording for the same UDID.
package struct RecordedTouchListenerGeneration: Codable, Equatable, Sendable {
    package let token: UUID

    package init(token: UUID) {
        self.token = token
    }

    package init(ownershipPath: String) throws {
        let fd = Darwin.open(ownershipPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw RecordedTouchRecoveryJournalError.syscall(
                operation: "open listener ownership",
                errorNumber: errno
            )
        }
        defer { Darwin.close(fd) }
        var fileStat = stat()
        guard fstat(fd, &fileStat) == 0 else {
            throw RecordedTouchRecoveryJournalError.syscall(
                operation: "fstat listener ownership",
                errorNumber: errno
            )
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_uid == getuid() else {
            throw RecordedTouchRecoveryJournalError.invalidOwnershipFile(
                path: ownershipPath
            )
        }
        guard lseek(fd, 0, SEEK_SET) >= 0 else {
            throw RecordedTouchRecoveryJournalError.syscall(
                operation: "seek listener ownership",
                errorNumber: errno
            )
        }
        var bytes = [UInt8](repeating: 0, count: 128)
        let count: Int
        while true {
            let result = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress, buffer.count)
            }
            if result < 0, errno == EINTR { continue }
            count = result
            break
        }
        guard count > 0,
              let text = String(bytes: bytes.prefix(count), encoding: .utf8),
              let generationLine = text.split(whereSeparator: \.isNewline)
                .dropFirst().first,
              let token = UUID(uuidString: String(generationLine)) else {
            throw RecordedTouchRecoveryJournalError.invalidOwnershipFile(
                path: ownershipPath
            )
        }
        self.init(token: token)
    }

    package var fileComponent: String {
        token.uuidString
    }
}

package struct RecordedTouchRecoveryBatch: Equatable, Sendable {
    package let events: [RecordedTouchEvent]
    package let diagnostics: [String]
}

package enum RecordedTouchRecoveryJournalError: Error, LocalizedError, Equatable {
    case invalidOwnershipFile(path: String)
    case invalidMailbox(path: String)
    case invalidEventFile(path: String)
    case generationMismatch
    case mailboxFull(limit: Int)
    case unsupportedContactID(UInt32)
    case payloadTooLarge(bytes: Int, limit: Int)
    case malformedPayload(String)
    case syscall(operation: String, errorNumber: Int32)

    package var errorDescription: String? {
        switch self {
        case .invalidOwnershipFile(let path):
            "Recorded-touch listener ownership path is not a trusted regular file: \(path)"
        case .invalidMailbox(let path):
            "Recorded-touch recovery mailbox is not a trusted directory: \(path)"
        case .invalidEventFile(let path):
            "Recorded-touch recovery event is not a trusted regular file: \(path)"
        case .generationMismatch:
            "Recorded-touch recovery event belongs to a different listener generation."
        case .mailboxFull(let limit):
            "Recorded-touch recovery mailbox already contains \(limit) pending events."
        case .unsupportedContactID(let contactID):
            "Recorded-touch recovery cannot persist unknown contact ID \(contactID)."
        case .payloadTooLarge(let bytes, let limit):
            "Recorded-touch recovery event is \(bytes) bytes, exceeding the \(limit)-byte limit."
        case .malformedPayload(let message):
            "Recorded-touch recovery event is malformed: \(message)"
        case .syscall(let operation, let errorNumber):
            "Recorded-touch recovery mailbox \(operation) failed (errno=\(errorNumber)): \(String(cString: strerror(errorNumber)))"
        }
    }
}

/// Rare-path reliable control plane for terminal events whose nonblocking
/// datagram delivery failed after HID had already acknowledged the input.
///
/// Each logical event owns one atomically-published file. The main slots never
/// wait on the listener or another writer; overflow probes independent
/// per-contact candidates for at most 10 ms while preserving the latest
/// terminal timestamp. A failed write cannot corrupt terminal events that were
/// already queued, and the listener drains bounded state on each maintenance
/// tick.
package enum RecordedTouchRecoveryJournal {
    private struct Envelope: Codable {
        let version: Int
        let generation: RecordedTouchListenerGeneration
        let sourceEventID: UUID
        let event: RecordedTouchEvent
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    package static let currentVersion = 1
    package static let maximumEventCount = 64
    package static let maximumPayloadBytes = 256 * 1024
    package static let emergencyCandidateCount = 8
    package static let maximumMailboxPayloadBytes = maximumEventCount
        * maximumPayloadBytes * 2
        + 3 * emergencyCandidateCount * maximumPayloadBytes * 2
    private static let recoverableContactIDs: ClosedRange<UInt32> = 0...2
    private static let emergencyContentionTimeoutNanoseconds: UInt64 = 10_000_000

    @discardableResult
    package static func appendTerminalEvent(
        _ event: RecordedTouchEvent,
        generation: RecordedTouchListenerGeneration,
        at mailboxURL: URL
    ) throws -> Bool {
        guard let terminalEvent = terminalOnly(event) else { return false }
        let encoded = try JSONEncoder().encode(Envelope(
            version: currentVersion,
            generation: generation,
            sourceEventID: terminalEvent.eventID,
            event: terminalEvent
        ))
        guard encoded.count <= maximumPayloadBytes else {
            throw RecordedTouchRecoveryJournalError.payloadTooLarge(
                bytes: encoded.count,
                limit: maximumPayloadBytes
            )
        }

        try ensureMailbox(at: mailboxURL)
        do {
            try publishEventFile(
                encoded,
                eventID: terminalEvent.eventID,
                in: mailboxURL
            )
        } catch RecordedTouchRecoveryJournalError.mailboxFull {
            try publishEmergencyTerminalEvents(
                terminalEvent,
                generation: generation,
                in: mailboxURL
            )
        }
        return true
    }

    package static func consume(
        generation: RecordedTouchListenerGeneration,
        at mailboxURL: URL
    ) throws -> RecordedTouchRecoveryBatch? {
        guard try mailboxExists(at: mailboxURL) else { return nil }
        reapAbandonedPendingFiles(in: mailboxURL)
        let discovered = try eventURLs(in: mailboxURL)
        let eventURLs = discovered.urls
        guard !eventURLs.isEmpty || !discovered.diagnostics.isEmpty else { return nil }

        var events: [RecordedTouchEvent] = []
        var newestEmergencyByContactID: [UInt32: RecordedTouchEvent] = [:]
        var diagnostics = discovered.diagnostics
        events.reserveCapacity(eventURLs.count)
        for eventURL in eventURLs {
            do {
                let event = try consumeEvent(
                    at: eventURL,
                    generation: generation
                )
                if eventURL.lastPathComponent.hasPrefix("emergency-") {
                    guard event.samples.count == 1,
                          event.samples[0].relativeNanoseconds == 0,
                          event.samples[0].contacts.count == 1,
                          let contact = event.samples[0].contacts.first,
                          contact.phase == .ended || contact.phase == .cancelled else {
                        diagnostics.append(
                            "Recorded-touch emergency recovery event has an invalid contact shape."
                        )
                        continue
                    }
                    if let existing = newestEmergencyByContactID[contact.contactID],
                       existing.dispatchUptimeNanoseconds
                            > event.dispatchUptimeNanoseconds {
                        continue
                    }
                    newestEmergencyByContactID[contact.contactID] = event
                } else {
                    events.append(event)
                }
            } catch {
                diagnostics.append(error.localizedDescription)
            }
        }
        events.append(contentsOf: newestEmergencyByContactID.values)
        events.sort {
            if $0.dispatchUptimeNanoseconds == $1.dispatchUptimeNanoseconds {
                return $0.eventID.uuidString < $1.eventID.uuidString
            }
            return $0.dispatchUptimeNanoseconds < $1.dispatchUptimeNanoseconds
        }
        return RecordedTouchRecoveryBatch(
            events: events,
            diagnostics: diagnostics
        )
    }

    package static func remove(at mailboxURL: URL) {
        var fileStat = stat()
        guard lstat(mailboxURL.path, &fileStat) == 0 else { return }
        guard fileStat.st_uid == getuid() else { return }
        if (fileStat.st_mode & S_IFMT) == S_IFREG {
            _ = unlink(mailboxURL.path)
            return
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFDIR else { return }
        try? FileManager.default.removeItem(at: mailboxURL)
    }

    package static func remove(
        event: RecordedTouchEvent,
        at mailboxURL: URL
    ) {
        guard let urls = try? eventURLs(in: mailboxURL).urls else { return }
        for url in urls {
            guard let (envelope, identity) = try? readEnvelope(at: url),
                  envelope.sourceEventID == event.eventID else { continue }
            removePathIfOwned(url, identity: identity)
        }
    }

    package static func removeStaleFiles(
        in directory: URL,
        udid: String,
        keeping currentURL: URL
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let prefix = "\(udid)."
        for entry in entries where entry.pathExtension == "recovery" {
            guard entry != currentURL,
                  entry.lastPathComponent.hasPrefix(prefix) else { continue }
            remove(at: entry)
        }
    }

    private static func terminalOnly(
        _ event: RecordedTouchEvent
    ) -> RecordedTouchEvent? {
        let samples = event.samples.compactMap { sample -> RecordedTouchSample? in
            let contacts = sample.contacts.filter {
                $0.phase == .ended || $0.phase == .cancelled
            }
            guard !contacts.isEmpty else { return nil }
            return RecordedTouchSample(
                relativeNanoseconds: sample.relativeNanoseconds,
                contacts: contacts
            )
        }
        guard !samples.isEmpty else { return nil }
        return RecordedTouchEvent(
            version: event.version,
            udid: event.udid,
            eventID: event.eventID,
            dispatchUptimeNanoseconds: event.dispatchUptimeNanoseconds,
            samples: samples
        )
    }

    private static func ensureMailbox(at url: URL) throws {
        if mkdir(url.path, mode_t(0o700)) != 0, errno != EEXIST {
            throw RecordedTouchRecoveryJournalError.syscall(
                operation: "create mailbox",
                errorNumber: errno
            )
        }
        var fileStat = stat()
        guard lstat(url.path, &fileStat) == 0 else {
            throw RecordedTouchRecoveryJournalError.syscall(
                operation: "inspect mailbox",
                errorNumber: errno
            )
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFDIR,
              fileStat.st_uid == getuid() else {
            throw RecordedTouchRecoveryJournalError.invalidMailbox(path: url.path)
        }
        guard chmod(url.path, 0o700) == 0 else {
            throw RecordedTouchRecoveryJournalError.syscall(
                operation: "chmod mailbox",
                errorNumber: errno
            )
        }
    }

    private static func mailboxExists(at url: URL) throws -> Bool {
        var fileStat = stat()
        guard lstat(url.path, &fileStat) == 0 else {
            if errno == ENOENT { return false }
            throw RecordedTouchRecoveryJournalError.syscall(
                operation: "inspect mailbox",
                errorNumber: errno
            )
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFDIR,
              fileStat.st_uid == getuid() else {
            throw RecordedTouchRecoveryJournalError.invalidMailbox(path: url.path)
        }
        return true
    }

    private static func publishEventFile(
        _ data: Data,
        eventID: UUID,
        in mailboxURL: URL
    ) throws {
        let firstSlot = stableSlot(for: eventID)
        for offset in 0..<maximumEventCount {
            let slot = (firstSlot + offset) % maximumEventCount
            let lockURL = slotURL(slot, extension: "lock", in: mailboxURL)
            guard let lockFD = try tryLockFile(at: lockURL) else { continue }
            defer {
                _ = flock(lockFD, LOCK_UN)
                Darwin.close(lockFD)
            }
            let pendingURL = slotURL(slot, extension: "pending", in: mailboxURL)
            let finalURL = slotURL(slot, extension: "json", in: mailboxURL)
            let fd = Darwin.open(
                pendingURL.path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
            if fd < 0, errno == EEXIST { continue }
            guard fd >= 0 else {
                throw RecordedTouchRecoveryJournalError.syscall(
                    operation: "claim event slot",
                    errorNumber: errno
                )
            }
            var pendingStat = stat()
            guard fstat(fd, &pendingStat) == 0 else {
                let errorNumber = errno
                Darwin.close(fd)
                throw RecordedTouchRecoveryJournalError.syscall(
                    operation: "inspect pending event",
                    errorNumber: errorNumber
                )
            }
            let pendingIdentity = FileIdentity(
                device: pendingStat.st_dev,
                inode: pendingStat.st_ino
            )
            var shouldClose = true
            defer {
                if shouldClose { Darwin.close(fd) }
                removePathIfOwned(pendingURL, identity: pendingIdentity)
            }

            var finalStat = stat()
            if lstat(finalURL.path, &finalStat) == 0 {
                Darwin.close(fd)
                shouldClose = false
                continue
            }
            guard errno == ENOENT else {
                throw RecordedTouchRecoveryJournalError.syscall(
                    operation: "inspect event slot",
                    errorNumber: errno
                )
            }

            try configureAndWrite(data, to: fd, path: pendingURL.path)
            guard rename(pendingURL.path, finalURL.path) == 0 else {
                throw RecordedTouchRecoveryJournalError.syscall(
                    operation: "publish event",
                    errorNumber: errno
                )
            }
            guard Darwin.close(fd) == 0 else {
                shouldClose = false
                throw RecordedTouchRecoveryJournalError.syscall(
                    operation: "close event",
                    errorNumber: errno
                )
            }
            shouldClose = false
            return
        }
        throw RecordedTouchRecoveryJournalError.mailboxFull(
            limit: maximumEventCount
        )
    }

    private static func configureAndWrite(
        _ data: Data,
        to fd: Int32,
        path: String
    ) throws {
        var fileStat = stat()
        guard fstat(fd, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_uid == getuid() else {
            throw RecordedTouchRecoveryJournalError.invalidEventFile(path: path)
        }
        guard fchmod(fd, 0o600) == 0 else {
            throw RecordedTouchRecoveryJournalError.syscall(
                operation: "chmod event",
                errorNumber: errno
            )
        }

        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.write(
                    fd,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw RecordedTouchRecoveryJournalError.syscall(
                    operation: "write event",
                    errorNumber: errno
                )
            }
            guard written > 0 else {
                throw RecordedTouchRecoveryJournalError.syscall(
                    operation: "write event",
                    errorNumber: EIO
                )
            }
            offset += written
        }
    }

    private static func stableSlot(for eventID: UUID) -> Int {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in eventID.uuidString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(maximumEventCount))
    }

    private static func slotURL(
        _ slot: Int,
        extension pathExtension: String,
        in mailboxURL: URL
    ) -> URL {
        mailboxURL.appendingPathComponent(
            String(format: "slot-%02d.%@", slot, pathExtension),
            isDirectory: false
        )
    }

    private static func eventURLs(
        in mailboxURL: URL
    ) throws -> (urls: [URL], diagnostics: [String]) {
        var candidates = (0..<maximumEventCount).map {
            slotURL($0, extension: "json", in: mailboxURL)
        }
        for contactID in recoverableContactIDs {
            candidates.append(contentsOf: (0..<emergencyCandidateCount).map {
                emergencyURL(
                    contactID,
                    candidate: $0,
                    extension: "json",
                    in: mailboxURL
                )
            })
        }
        let allowedNames = Set(candidates.map(\.lastPathComponent))
        let entries = try FileManager.default.contentsOfDirectory(
            at: mailboxURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var urls: [URL] = []
        var diagnostics: [String] = []
        for url in entries where allowedNames.contains(url.lastPathComponent) {
            var fileStat = stat()
            guard lstat(url.path, &fileStat) == 0 else {
                if errno == ENOENT { continue }
                throw RecordedTouchRecoveryJournalError.syscall(
                    operation: "inspect event slot",
                    errorNumber: errno
                )
            }
            guard (fileStat.st_mode & S_IFMT) == S_IFREG,
                  fileStat.st_uid == getuid() else {
                if fileStat.st_uid == getuid() {
                    diagnostics.append(
                        "Removed invalid recorded-touch recovery slot: \(url.path)"
                    )
                    removeSlotArtifactIfSafe(url, stat: fileStat)
                } else {
                    diagnostics.append(
                        "Ignored untrusted recorded-touch recovery slot: \(url.path)"
                    )
                }
                continue
            }
            urls.append(url)
        }
        return (urls, diagnostics)
    }

    private static func publishEmergencyTerminalEvents(
        _ event: RecordedTouchEvent,
        generation: RecordedTouchListenerGeneration,
        in mailboxURL: URL
    ) throws {
        struct LatestContact {
            let contact: RecordedTouchContact
            let uptimeNanoseconds: UInt64
        }
        var latestByID: [UInt32: LatestContact] = [:]
        for sample in event.samples {
            let (uptime, overflow) = event.dispatchUptimeNanoseconds
                .addingReportingOverflow(sample.relativeNanoseconds)
            guard !overflow else {
                throw RecordedTouchRecoveryJournalError.malformedPayload(
                    "terminal contact timestamp overflowed"
                )
            }
            for contact in sample.contacts {
                guard recoverableContactIDs.contains(contact.contactID) else {
                    throw RecordedTouchRecoveryJournalError.unsupportedContactID(
                        contact.contactID
                    )
                }
                if let existing = latestByID[contact.contactID],
                   existing.uptimeNanoseconds > uptime {
                    continue
                }
                latestByID[contact.contactID] = LatestContact(
                    contact: contact,
                    uptimeNanoseconds: uptime
                )
            }
        }

        var firstError: Error?
        for (contactID, latest) in latestByID.sorted(by: { $0.key < $1.key }) {
            let emergencyEvent = RecordedTouchEvent(
                version: event.version,
                udid: event.udid,
                dispatchUptimeNanoseconds: latest.uptimeNanoseconds,
                samples: [RecordedTouchSample(
                    relativeNanoseconds: 0,
                    contacts: [latest.contact]
                )]
            )
            let encoded = try JSONEncoder().encode(Envelope(
                version: currentVersion,
                generation: generation,
                sourceEventID: event.eventID,
                event: emergencyEvent
            ))
            guard encoded.count <= maximumPayloadBytes else {
                throw RecordedTouchRecoveryJournalError.payloadTooLarge(
                    bytes: encoded.count,
                    limit: maximumPayloadBytes
                )
            }
            do {
                try publishEmergencyEventFile(
                    encoded,
                    event: emergencyEvent,
                    contactID: contactID,
                    generation: generation,
                    in: mailboxURL
                )
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private static func publishEmergencyEventFile(
        _ data: Data,
        event: RecordedTouchEvent,
        contactID: UInt32,
        generation: RecordedTouchListenerGeneration,
        in mailboxURL: URL
    ) throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while true {
            for candidate in 0..<emergencyCandidateCount {
                let lockURL = emergencyURL(
                    contactID,
                    candidate: candidate,
                    extension: "lock",
                    in: mailboxURL
                )
                guard let lockFD = try tryLockFile(at: lockURL) else { continue }
                defer {
                    _ = flock(lockFD, LOCK_UN)
                    Darwin.close(lockFD)
                }
                let finalURL = emergencyURL(
                    contactID,
                    candidate: candidate,
                    extension: "json",
                    in: mailboxURL
                )
                if let (existing, _) = try? readEnvelope(at: finalURL),
                   existing.version == currentVersion,
                   existing.generation == generation,
                   existing.event.dispatchUptimeNanoseconds
                        >= event.dispatchUptimeNanoseconds {
                    return
                }

                let pendingURL = emergencyURL(
                    contactID,
                    candidate: candidate,
                    extension: "pending",
                    in: mailboxURL
                )
                removeArtifactIfOwned(pendingURL)
                let fd = Darwin.open(
                    pendingURL.path,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(0o600)
                )
                guard fd >= 0 else {
                    throw RecordedTouchRecoveryJournalError.syscall(
                        operation: "create emergency event",
                        errorNumber: errno
                    )
                }
                var pendingStat = stat()
                guard fstat(fd, &pendingStat) == 0 else {
                    let errorNumber = errno
                    Darwin.close(fd)
                    throw RecordedTouchRecoveryJournalError.syscall(
                        operation: "inspect emergency event",
                        errorNumber: errorNumber
                    )
                }
                let identity = FileIdentity(
                    device: pendingStat.st_dev,
                    inode: pendingStat.st_ino
                )
                defer {
                    Darwin.close(fd)
                    removePathIfOwned(pendingURL, identity: identity)
                }
                try configureAndWrite(data, to: fd, path: pendingURL.path)
                guard rename(pendingURL.path, finalURL.path) == 0 else {
                    throw RecordedTouchRecoveryJournalError.syscall(
                        operation: "publish emergency event",
                        errorNumber: errno
                    )
                }
                return
            }

            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= start,
                  now - start < emergencyContentionTimeoutNanoseconds else {
                throw RecordedTouchRecoveryJournalError.mailboxFull(
                    limit: emergencyCandidateCount
                )
            }
            sched_yield()
        }
    }

    private static func reapAbandonedPendingFiles(in mailboxURL: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: mailboxURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for pendingURL in entries where pendingURL.pathExtension == "pending" {
            let lockURL = pendingURL.deletingPathExtension()
                .appendingPathExtension("lock")
            var lockStat = stat()
            guard lstat(lockURL.path, &lockStat) == 0 else {
                // A conforming writer publishes the stable lock before its
                // pending path. No lock therefore means no live owner.
                if errno == ENOENT { removeArtifactIfOwned(pendingURL) }
                continue
            }
            guard let lockFD = try? tryLockFile(at: lockURL) else { continue }
            removeArtifactIfOwned(pendingURL)
            _ = flock(lockFD, LOCK_UN)
            Darwin.close(lockFD)
        }
    }

    private static func emergencyURL(
        _ contactID: UInt32,
        candidate: Int,
        extension pathExtension: String,
        in mailboxURL: URL
    ) -> URL {
        mailboxURL.appendingPathComponent(
            String(
                format: "emergency-%u-%02d.%@",
                contactID,
                candidate,
                pathExtension
            ),
            isDirectory: false
        )
    }

    private static func tryLockFile(at url: URL) throws -> Int32? {
        let fd = try openLockFile(at: url)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let errorNumber = errno
            Darwin.close(fd)
            if errorNumber == EWOULDBLOCK { return nil }
            throw RecordedTouchRecoveryJournalError.syscall(
                operation: "lock slot",
                errorNumber: errorNumber
            )
        }
        return fd
    }

    private static func openLockFile(at url: URL) throws -> Int32 {
        let fd = Darwin.open(
            url.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard fd >= 0 else {
            throw RecordedTouchRecoveryJournalError.syscall(
                operation: "open slot lock",
                errorNumber: errno
            )
        }
        var fileStat = stat()
        guard fstat(fd, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_uid == getuid() else {
            Darwin.close(fd)
            throw RecordedTouchRecoveryJournalError.invalidEventFile(path: url.path)
        }
        guard fchmod(fd, 0o600) == 0 else {
            let errorNumber = errno
            Darwin.close(fd)
            throw RecordedTouchRecoveryJournalError.syscall(
                operation: "chmod slot lock",
                errorNumber: errorNumber
            )
        }
        return fd
    }

    private static func removeArtifactIfOwned(_ url: URL) {
        var fileStat = stat()
        guard lstat(url.path, &fileStat) == 0,
              fileStat.st_uid == getuid() else { return }
        removeSlotArtifactIfSafe(url, stat: fileStat)
    }

    private static func removeSlotArtifactIfSafe(
        _ url: URL,
        stat observedStat: stat
    ) {
        var currentStat = stat()
        guard lstat(url.path, &currentStat) == 0,
              currentStat.st_dev == observedStat.st_dev,
              currentStat.st_ino == observedStat.st_ino,
              currentStat.st_uid == observedStat.st_uid,
              (currentStat.st_mode & S_IFMT)
                == (observedStat.st_mode & S_IFMT) else { return }
        if (currentStat.st_mode & S_IFMT) == S_IFDIR {
            try? FileManager.default.removeItem(at: url)
        } else {
            _ = unlink(url.path)
        }
    }

    private static func consumeEvent(
        at url: URL,
        generation: RecordedTouchListenerGeneration
    ) throws -> RecordedTouchEvent {
        let (envelope, _) = try readEnvelope(
            at: url,
            removeAfterRead: true
        )
        guard envelope.version == currentVersion,
              envelope.generation == generation else {
            throw RecordedTouchRecoveryJournalError.generationMismatch
        }
        return envelope.event
    }

    private static func readEnvelope(
        at url: URL,
        removeAfterRead: Bool = false
    ) throws -> (Envelope, FileIdentity) {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw RecordedTouchRecoveryJournalError.syscall(
                operation: "open event",
                errorNumber: errno
            )
        }
        defer { Darwin.close(fd) }
        var fileStat = stat()
        guard fstat(fd, &fileStat) == 0 else {
            throw RecordedTouchRecoveryJournalError.syscall(
                operation: "inspect event",
                errorNumber: errno
            )
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_uid == getuid() else {
            throw RecordedTouchRecoveryJournalError.invalidEventFile(path: url.path)
        }
        let identity = FileIdentity(
            device: fileStat.st_dev,
            inode: fileStat.st_ino
        )
        defer {
            if removeAfterRead {
                removePathIfOwned(url, identity: identity)
            }
        }
        guard fileStat.st_size <= maximumPayloadBytes else {
            throw RecordedTouchRecoveryJournalError.payloadTooLarge(
                bytes: Int(fileStat.st_size),
                limit: maximumPayloadBytes
            )
        }

        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress, buffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw RecordedTouchRecoveryJournalError.syscall(
                    operation: "read event",
                    errorNumber: errno
                )
            }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= maximumPayloadBytes else {
                throw RecordedTouchRecoveryJournalError.payloadTooLarge(
                    bytes: data.count,
                    limit: maximumPayloadBytes
                )
            }
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw RecordedTouchRecoveryJournalError.malformedPayload(
                error.localizedDescription
            )
        }
        return (envelope, identity)
    }

    private static func removePathIfOwned(
        _ url: URL,
        identity: FileIdentity
    ) {
        var fileStat = stat()
        guard lstat(url.path, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_uid == getuid(),
              FileIdentity(device: fileStat.st_dev, inode: fileStat.st_ino)
                == identity else { return }
        _ = unlink(url.path)
    }
}
