import Foundation

/// Bounded buffer of the most recent terminal output. Oldest bytes are dropped once `capacity` is
/// exceeded. Used to replay a terminal when its view is recreated, and (P2) persisted to disk.
public struct ScrollbackRing: Sendable {
    public static let defaultCapacity = 4 * 1024 * 1024

    public let capacity: Int
    private var storage: [UInt8]
    private var start = 0
    public private(set) var count = 0
    /// Total bytes ever appended, including dropped ones.
    public private(set) var totalAppended: UInt64 = 0

    public init(capacity: Int = ScrollbackRing.defaultCapacity) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = [UInt8](repeating: 0, count: capacity)
    }

    public mutating func append(_ data: Data) {
        totalAppended += UInt64(data.count)
        // Only the last `capacity` bytes of an oversized chunk can survive.
        let bytes = data.count > capacity ? data.suffix(capacity) : data[...]
        guard !bytes.isEmpty else { return }
        storage.withUnsafeMutableBytes { ring in
            bytes.withUnsafeBytes { source in
                var offset = 0
                var end = (start + count) % capacity
                while offset < source.count {
                    let run = min(source.count - offset, capacity - end)
                    UnsafeMutableRawBufferPointer(rebasing: ring[end..<(end + run)])
                        .copyMemory(from: UnsafeRawBufferPointer(rebasing: source[offset..<(offset + run)]))
                    offset += run
                    end = (end + run) % capacity
                }
            }
        }
        let overflow = count + bytes.count - capacity
        if overflow > 0 {
            start = (start + overflow) % capacity
            count = capacity
        } else {
            count += bytes.count
        }
    }

    public var contents: Data {
        var result = Data(capacity: count)
        let firstRun = min(count, capacity - start)
        result.append(contentsOf: storage[start..<(start + firstRun)])
        if firstRun < count {
            result.append(contentsOf: storage[0..<(count - firstRun)])
        }
        return result
    }

    public mutating func removeAll() {
        start = 0
        count = 0
    }
}
