// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Per-UDID paths for the ordered recording touch stream.
package struct RecordedTouchStreamPaths: Sendable {
    package let udid: String
    package let baseDirectory: URL

    package init(udid: String, baseDirectory: URL? = nil) {
        self.udid = udid
        self.baseDirectory = baseDirectory ?? DaemonPaths.defaultBaseDirectory
    }

    package var channelDirectory: URL {
        baseDirectory.appendingPathComponent("touch", isDirectory: true)
    }

    package var socketURL: URL {
        channelDirectory.appendingPathComponent("\(udid).sock", isDirectory: false)
    }

    package var lockURL: URL {
        channelDirectory.appendingPathComponent("\(udid).lock", isDirectory: false)
    }

    package func ensureSecureChannelDirectory() throws {
        try DaemonPaths(udid: udid, baseDirectory: baseDirectory).ensureBaseDirectory()
        try FileManager.default.createDirectory(
            at: channelDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try DaemonPaths.validateBaseDirectory(at: channelDirectory)
    }
}
