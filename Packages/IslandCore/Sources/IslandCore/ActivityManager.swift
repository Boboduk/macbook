import Foundation

/// Single source of truth for everything the island may show.
///
/// * **Live activities** (music, timer) are kept in a dictionary; the one with
///   the highest priority (then the most recently updated) is `primaryLive`.
/// * **Transient activities** (HUDs, notifications) are shown one at a time.
///   `currentTransient` is on screen, the rest wait in a priority queue.
///
/// Conflict rules:
/// 1. An update with the id of the visible transient changes it in place
///    (no new opening animation) and, depending on `updatePolicy`, restarts
///    its countdown.
/// 2. An update with the id of a queued item replaces that item.
/// 3. A new transient with a *higher* priority preempts the visible one. The
///    preempted one is requeued with its remaining time if
///    `requeueOnPreempt` is set, otherwise it is dropped.
/// 4. Everything else waits in the queue (priority, then FIFO). The queue is
///    bounded; the least important, newest item is dropped on overflow.
/// 5. While held (cursor over the island, slider being dragged) the visible
///    transient does not expire; after release it gets at least a grace period.
///
/// Not thread-safe: use from one thread (the main thread in the app).
public final class ActivityManager {
    public struct Configuration: Equatable {
        public var maxQueueLength: Int
        /// Minimum display time given to a requeued, preempted activity.
        public var minimumRequeueDuration: TimeInterval
        /// Minimum display time left after a hold is released.
        public var holdGracePeriod: TimeInterval

        public init(maxQueueLength: Int = 8, minimumRequeueDuration: TimeInterval = 1.5, holdGracePeriod: TimeInterval = 1.2) {
            self.maxQueueLength = maxQueueLength
            self.minimumRequeueDuration = minimumRequeueDuration
            self.holdGracePeriod = holdGracePeriod
        }
    }

    private struct QueuedItem {
        var activity: Activity
        /// Remaining time for a preempted activity; `nil` means its full duration.
        var remaining: TimeInterval?
        var sequence: Int
    }

    public let configuration: Configuration
    public private(set) var liveActivities: [ActivityID: Activity] = [:]
    public private(set) var currentTransient: Activity?
    public private(set) var isHeld = false

    /// Called after every visible change. Not called for no-op calls.
    public var onChange: (() -> Void)?

    private let scheduler: IslandScheduler
    private var queue: [QueuedItem] = []
    private var sequence = 0
    private var transientDeadline: Date?
    private var heldRemaining: TimeInterval?
    private var transientToken: SchedulerToken?
    private var liveExpiryTokens: [ActivityID: SchedulerToken] = [:]

    public init(scheduler: IslandScheduler, configuration: Configuration = Configuration()) {
        self.scheduler = scheduler
        self.configuration = configuration
    }

    // MARK: - Queries

    public var queuedActivities: [Activity] { queue.map(\.activity) }

    /// The live activity shown in the compact island.
    public var primaryLive: Activity? {
        liveActivities.values.max { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            return lhs.id.rawValue > rhs.id.rawValue
        }
    }

    public func activity(withID id: ActivityID) -> Activity? {
        if let live = liveActivities[id] { return live }
        if currentTransient?.id == id { return currentTransient }
        return queue.first { $0.activity.id == id }?.activity
    }

    /// Seconds until the visible transient disappears (`nil` while held or idle).
    public var currentTransientRemaining: TimeInterval? {
        guard let deadline = transientDeadline else { return nil }
        return max(0, deadline.timeIntervalSince(scheduler.now))
    }

    // MARK: - Mutations

    public func upsert(_ activity: Activity) {
        switch activity.lifetime {
        case let .live(expiresAfter):
            removeTransient(withID: activity.id, notify: false)
            upsertLive(activity, expiresAfter: expiresAfter)
        case let .transient(duration):
            if liveActivities[activity.id] != nil {
                liveActivities[activity.id] = nil
                liveExpiryTokens.removeValue(forKey: activity.id)?.cancel()
            }
            upsertTransient(activity, duration: duration)
        }
        notify()
    }

    /// Ends an activity wherever it is. Returns `true` if something was removed.
    @discardableResult
    public func end(_ id: ActivityID) -> Bool {
        var changed = false
        if liveActivities.removeValue(forKey: id) != nil {
            liveExpiryTokens.removeValue(forKey: id)?.cancel()
            changed = true
        }
        if removeTransient(withID: id, notify: false) { changed = true }
        if changed { notify() }
        return changed
    }

    /// Ends every activity of a module (used when the module is disabled).
    public func endAll(kind: ActivityKind) {
        var ids = Set(liveActivities.values.filter { $0.kind == kind }.map(\.id))
        ids.formUnion(queue.filter { $0.activity.kind == kind }.map(\.activity.id))
        if let current = currentTransient, current.kind == kind { ids.insert(current.id) }
        guard !ids.isEmpty else { return }
        for id in ids {
            if liveActivities.removeValue(forKey: id) != nil {
                liveExpiryTokens.removeValue(forKey: id)?.cancel()
            }
            removeTransient(withID: id, notify: false)
        }
        notify()
    }

    /// Hides the visible transient now; the next queued one (if any) follows.
    public func dismissCurrentTransient() {
        guard let current = currentTransient else { return }
        end(current.id)
    }

    public func removeAll() {
        let hadContent = currentTransient != nil || !queue.isEmpty || !liveActivities.isEmpty
        transientToken?.cancel()
        transientToken = nil
        transientDeadline = nil
        heldRemaining = nil
        currentTransient = nil
        queue.removeAll()
        liveExpiryTokens.values.forEach { $0.cancel() }
        liveExpiryTokens.removeAll()
        liveActivities.removeAll()
        if hadContent { notify() }
    }

    /// Pauses (or resumes) expiry of the visible transient.
    public func setHold(_ held: Bool) {
        guard held != isHeld else { return }
        isHeld = held
        if held {
            if let deadline = transientDeadline {
                heldRemaining = max(0, deadline.timeIntervalSince(scheduler.now))
            }
            transientToken?.cancel()
            transientToken = nil
            transientDeadline = nil
        } else if currentTransient != nil {
            let remaining = max(heldRemaining ?? 0, configuration.holdGracePeriod)
            heldRemaining = nil
            scheduleTransientExpiry(after: remaining)
        }
    }

    // MARK: - Live

    private func upsertLive(_ activity: Activity, expiresAfter: TimeInterval?) {
        var stamped = activity
        stamped.createdAt = liveActivities[activity.id]?.createdAt ?? scheduler.now
        stamped.updatedAt = scheduler.now
        liveActivities[activity.id] = stamped

        liveExpiryTokens.removeValue(forKey: activity.id)?.cancel()
        if let expiresAfter {
            let id = activity.id
            liveExpiryTokens[id] = scheduler.schedule(after: expiresAfter) { [weak self] in
                self?.liveExpiryTokens[id] = nil
                self?.end(id)
            }
        }
    }

    // MARK: - Transient

    private func upsertTransient(_ activity: Activity, duration: TimeInterval) {
        // 1. Update of the visible transient.
        if let current = currentTransient, current.id == activity.id {
            currentTransient = stamped(activity, preserving: current)
            if activity.updatePolicy == .restartTimer {
                if isHeld {
                    heldRemaining = duration
                } else {
                    scheduleTransientExpiry(after: duration)
                }
            }
            return
        }

        // 2. Update of a queued item.
        if let index = queue.firstIndex(where: { $0.activity.id == activity.id }) {
            queue[index].activity = stamped(activity, preserving: queue[index].activity)
            queue[index].remaining = nil
            sortQueue()
            return
        }

        let fresh = stamped(activity, preserving: nil)

        // 3. Nothing visible: show immediately.
        guard let current = currentTransient else {
            show(fresh, duration: duration)
            return
        }

        // 4. Preemption by a more important activity.
        if fresh.priority > current.priority {
            if current.requeueOnPreempt {
                let remaining = currentRemaining() ?? current.transientDuration ?? 0
                enqueue(current, remaining: max(remaining, configuration.minimumRequeueDuration), toFront: true)
            }
            show(fresh, duration: duration)
            return
        }

        // 5. Wait in line.
        enqueue(fresh, remaining: nil, toFront: false)
    }

    private func stamped(_ activity: Activity, preserving existing: Activity?) -> Activity {
        var result = activity
        result.createdAt = existing?.createdAt ?? scheduler.now
        result.updatedAt = scheduler.now
        return result
    }

    private func show(_ activity: Activity, duration: TimeInterval) {
        currentTransient = activity
        if isHeld {
            transientToken?.cancel()
            transientToken = nil
            transientDeadline = nil
            heldRemaining = duration
        } else {
            heldRemaining = nil
            scheduleTransientExpiry(after: duration)
        }
    }

    private func currentRemaining() -> TimeInterval? {
        if isHeld { return heldRemaining }
        return currentTransientRemaining
    }

    private func scheduleTransientExpiry(after delay: TimeInterval) {
        transientToken?.cancel()
        transientDeadline = scheduler.now.addingTimeInterval(delay)
        transientToken = scheduler.schedule(after: delay) { [weak self] in
            self?.transientDidExpire()
        }
    }

    private func transientDidExpire() {
        transientToken = nil
        transientDeadline = nil
        currentTransient = nil
        showNextFromQueue()
        notify()
    }

    private func showNextFromQueue() {
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        let duration = next.remaining ?? next.activity.transientDuration ?? configuration.minimumRequeueDuration
        show(next.activity, duration: duration)
    }

    private func enqueue(_ activity: Activity, remaining: TimeInterval?, toFront: Bool) {
        sequence += 1
        // Requeued items get a negative sequence so they come back first
        // among activities of the same priority.
        let order = toFront ? -sequence : sequence
        queue.append(QueuedItem(activity: activity, remaining: remaining, sequence: order))
        sortQueue()
        if queue.count > configuration.maxQueueLength {
            queue.removeLast(queue.count - configuration.maxQueueLength)
        }
    }

    private func sortQueue() {
        queue.sort { lhs, rhs in
            if lhs.activity.priority != rhs.activity.priority {
                return lhs.activity.priority > rhs.activity.priority
            }
            return lhs.sequence < rhs.sequence
        }
    }

    @discardableResult
    private func removeTransient(withID id: ActivityID, notify shouldNotify: Bool) -> Bool {
        var changed = false
        if let index = queue.firstIndex(where: { $0.activity.id == id }) {
            queue.remove(at: index)
            changed = true
        }
        if currentTransient?.id == id {
            transientToken?.cancel()
            transientToken = nil
            transientDeadline = nil
            heldRemaining = nil
            currentTransient = nil
            showNextFromQueue()
            changed = true
        }
        if changed && shouldNotify { notify() }
        return changed
    }

    private func notify() {
        onChange?()
    }
}
