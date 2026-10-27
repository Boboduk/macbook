import Foundation

/// Handle returned by `IslandScheduler.schedule`. Cancelling an already fired
/// or cancelled token is a no-op.
public protocol SchedulerToken: AnyObject {
    func cancel()
}

/// Abstraction over time so that every delay in the island (hover delay,
/// transient expiry, live-activity expiry) is deterministic in tests.
///
/// All calls happen on one thread (the main thread in the app). Implementations
/// must invoke actions on that same thread.
public protocol IslandScheduler: AnyObject {
    var now: Date { get }

    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> SchedulerToken
}

/// A scheduler driven manually by `advance(by:)`. Used by unit tests and
/// SwiftUI previews.
public final class ManualScheduler: IslandScheduler {
    private final class Item: SchedulerToken {
        let fireDate: Date
        let sequence: Int
        var action: (() -> Void)?

        init(fireDate: Date, sequence: Int, action: @escaping () -> Void) {
            self.fireDate = fireDate
            self.sequence = sequence
            self.action = action
        }

        func cancel() { action = nil }
    }

    public private(set) var now: Date
    private var items: [Item] = []
    private var sequence = 0

    public init(now: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        self.now = now
    }

    /// Number of scheduled actions that have neither fired nor been cancelled.
    public var pendingCount: Int { items.filter { $0.action != nil }.count }

    @discardableResult
    public func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> SchedulerToken {
        sequence += 1
        let item = Item(fireDate: now.addingTimeInterval(max(0, delay)), sequence: sequence, action: action)
        items.append(item)
        return item
    }

    /// Moves the clock forward, firing due actions in chronological order.
    /// Actions scheduled while advancing also fire if they fall in the window.
    public func advance(by interval: TimeInterval) {
        let target = now.addingTimeInterval(interval)
        while true {
            items.removeAll { $0.action == nil }
            let due = items
                .filter { $0.fireDate <= target }
                .min { ($0.fireDate, $0.sequence) < ($1.fireDate, $1.sequence) }
            guard let item = due else { break }
            now = max(now, item.fireDate)
            let action = item.action
            item.action = nil
            action?()
        }
        now = target
    }
}
