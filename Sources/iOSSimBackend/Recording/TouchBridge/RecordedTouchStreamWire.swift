// SPDX-License-Identifier: Apache-2.0
import Foundation

enum RecordedTouchStreamWire {
    static let maximumFrameBytes = 4 * 1024

    struct Message: Codable, Sendable {
        enum Kind: String, Codable, Sendable {
            case hello
            case update
        }

        let kind: Kind
        let publisherID: UUID?
        let primitive: RecordedTouchPrimitive?

        static func hello(publisherID: UUID) -> Self {
            Self(
                kind: .hello,
                publisherID: publisherID,
                primitive: nil
            )
        }

        static func update(_ primitive: RecordedTouchPrimitive) -> Self {
            Self(
                kind: .update,
                publisherID: nil,
                primitive: primitive
            )
        }
    }

    enum ValidatedMessage: Sendable {
        case hello(UUID)
        case update(RecordedTouchPrimitive)
    }

    static func encode(_ message: Message) throws -> Data {
        var data = try JSONEncoder().encode(message)
        guard data.count < maximumFrameBytes else {
            throw RecordedTouchStreamWireError.frameTooLarge(data.count)
        }
        data.append(0x0A)
        return data
    }

    static func decode(_ data: Data) throws -> ValidatedMessage {
        guard data.count < maximumFrameBytes else {
            throw RecordedTouchStreamWireError.frameTooLarge(data.count)
        }
        let message = try JSONDecoder().decode(Message.self, from: data)
        switch (message.kind, message.publisherID, message.primitive) {
        case (.hello, .some(let publisherID), nil):
            return .hello(publisherID)
        case (.update, nil, .some(let primitive))
            where RecordedTouchPrimitive.validContactCount.contains(primitive.contacts.count):
            return .update(primitive)
        case (.update, nil, .some(let primitive)):
            throw RecordedTouchPrimitiveError.invalidContactCount(primitive.contacts.count)
        default:
            throw RecordedTouchStreamWireError.invalidMessageShape
        }
    }
}

enum RecordedTouchStreamWireError: Error, LocalizedError {
    case frameTooLarge(Int)
    case invalidMessageShape

    var errorDescription: String? {
        switch self {
        case .frameTooLarge(let bytes):
            "Recorded touch stream frame is too large (\(bytes) bytes)."
        case .invalidMessageShape:
            "Recorded touch stream frame has an invalid shape."
        }
    }
}
