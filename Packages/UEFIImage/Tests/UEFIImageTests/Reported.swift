import Foundation

/// Where a progress closure puts what it is told. The closure is `@Sendable`
/// and is called from wherever the work is running, so what it writes into
/// cannot be a captured `var`.
final class Reported<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    func append(_ item: Element) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
