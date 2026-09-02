// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import SimUseCore

/// The single live/test seam for opening a publisher stream connection.
/// A `.connected` descriptor transfers to the publisher, which always closes it.
package struct RecordedTouchStreamConnector: Sendable {
    package enum Result: Sendable {
        case connected(Int32)
        case noListener
        case failed(String)
    }

    private let operation: @Sendable (String) -> Result

    package init(operation: @escaping @Sendable (String) -> Result) {
        self.operation = operation
    }

    package func connect(path: String) -> Result {
        operation(path)
    }

    package static let system = Self { path in
        do {
            return .connected(try DaemonSocket.connect(path: path))
        } catch let error as DaemonSocketError {
            guard case .syscallFailed(_, let errorNumber, _) = error,
                  errorNumber == ENOENT || errorNumber == ECONNREFUSED else {
                return .failed(error.description)
            }
            return .noListener
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
