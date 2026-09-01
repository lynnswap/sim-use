// SPDX-License-Identifier: Apache-2.0

/// Per-UDID owner of recorded-touch phase state and its simulator boot.
/// HID connection invalidation may preserve this store for a same-boot retry;
/// binding a different or unverifiable boot always creates a fresh normalizer.
@MainActor
final class RecordedTouchStateStore {
    private struct Entry {
        let bootToken: HIDBootToken
        let normalizer: RecordedTouchEventNormalizer
    }

    private var entries: [String: Entry] = [:]

    func normalizer(for udid: String, bootToken: HIDBootToken) -> RecordedTouchEventNormalizer {
        if let entry = entries[udid],
           HIDBootIdentity.isReusable(
               cachedToken: entry.bootToken,
               currentToken: bootToken
           ) {
            return entry.normalizer
        }

        let normalizer = RecordedTouchEventNormalizer()
        entries[udid] = Entry(bootToken: bootToken, normalizer: normalizer)
        return normalizer
    }

    func currentNormalizer(for udid: String) -> RecordedTouchEventNormalizer? {
        entries[udid]?.normalizer
    }

    func removeValue(for udid: String) {
        entries.removeValue(forKey: udid)
    }

    func removeAll() {
        entries.removeAll()
    }
}
