import Foundation
import IslandCore

/// `IslandScheduler` backed by the main dispatch queue. Every delay of the
/// island (hover, collapse, transient expiry) is a one-shot work item; nothing
/// repeats while the island is idle.
final class MainQueueScheduler: IslandScheduler {
    private final class Token: SchedulerToken {
        private let item: DispatchWorkItem

        init(_ item: DispatchWorkItem) {
            self.item = item
        }

        func cancel() {
            item.cancel()
        }
    }

    var now: Date { Date() }

    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> SchedulerToken {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: item)
        return Token(item)
    }
}
