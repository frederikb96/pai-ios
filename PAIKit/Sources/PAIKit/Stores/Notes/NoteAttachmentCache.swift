import Foundation

/// The files a note page has already fetched, so a view that scrolls out of a lazy list and back
/// draws its image from memory in its first frame instead of showing a placeholder and fetching
/// again.
///
/// Keyed by container and path. Bounded by bytes and by count, least recently used out first; a
/// single file larger than the byte bound is never kept.
struct NoteAttachmentCache {
    struct Key: Hashable {
        let containerId: String
        let path: String
    }

    let maxBytes: Int
    let maxEntries: Int
    private var entries: [Key: Data] = [:]
    /// Oldest use first.
    private var order: [Key] = []
    private(set) var totalBytes = 0

    init(maxBytes: Int = 64 * 1024 * 1024, maxEntries: Int = 64) {
        self.maxBytes = maxBytes
        self.maxEntries = maxEntries
    }

    var count: Int { entries.count }

    mutating func data(containerId: String, path: String) -> Data? {
        let key = Key(containerId: containerId, path: path)
        guard let data = entries[key] else { return nil }
        touch(key)
        return data
    }

    mutating func insert(_ data: Data, containerId: String, path: String) {
        let key = Key(containerId: containerId, path: path)
        remove(key)
        guard data.count <= maxBytes else { return }
        entries[key] = data
        order.append(key)
        totalBytes += data.count
        while totalBytes > maxBytes || entries.count > maxEntries, let oldest = order.first {
            remove(oldest)
        }
    }

    mutating func remove(containerId: String, path: String) {
        remove(Key(containerId: containerId, path: path))
    }

    private mutating func remove(_ key: Key) {
        guard let data = entries.removeValue(forKey: key) else { return }
        totalBytes -= data.count
        order.removeAll { $0 == key }
    }

    private mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
