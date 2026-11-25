import Foundation

struct ScanJob {
    var node: UInt32
    var path: String
}

/// Per-worker deques. Local push/pop is LIFO; a steal takes the opposite end (FIFO).
/// The queue holds node indices plus the path needed to list that directory, never file descriptors.
final class WorkStealingQueue {
    static let queuedCap = 64_000

    private let locks: [NSLock]
    private var deques: [[ScanJob]]
    private let stateLock = NSLock()
    private let cond = NSCondition()
    private var pending = 0
    private var idle = 0
    private var stop = false
    let workers: Int

    init(workers: Int) {
        let count = max(1, workers)
        self.workers = count
        self.locks = (0..<count).map { _ in NSLock() }
        self.deques = Array(repeating: [], count: count)
    }

    var queuedCount: Int {
        var total = 0
        for index in 0..<workers {
            locks[index].lock()
            total += deques[index].count
            locks[index].unlock()
        }
        return total
    }

    func push(_ job: ScanJob, worker: Int) {
        let index = worker % workers
        locks[index].lock()
        deques[index].append(job)
        locks[index].unlock()
        cond.lock()
        pending += 1
        cond.signal()
        cond.unlock()
    }

    func popLocal(worker: Int) -> ScanJob? {
        let index = worker % workers
        locks[index].lock()
        defer { locks[index].unlock() }
        guard !deques[index].isEmpty else { return nil }
        return deques[index].removeLast()
    }

    func steal(by worker: Int) -> ScanJob? {
        guard workers > 1 else { return nil }
        var victim = (worker &+ 1) % workers
        // A single random-ish victim, then a short scan, keeps cross-thread traffic to one lock.
        for _ in 0..<(workers - 1) {
            if victim != worker {
                locks[victim].lock()
                if !deques[victim].isEmpty {
                    let job = deques[victim].removeFirst()
                    locks[victim].unlock()
                    return job
                }
                locks[victim].unlock()
            }
            victim = (victim &+ 1) % workers
        }
        return nil
    }

    func finishOne() {
        cond.lock()
        pending -= 1
        if pending <= 0 {
            pending = 0
            stop = true
            cond.broadcast()
        }
        cond.unlock()
    }

    /// Returns false when every pushed job has finished.
    func waitForWork() -> Bool {
        cond.lock()
        defer { cond.unlock() }
        if stop || pending <= 0 {
            stop = true
            return false
        }
        idle += 1
        if idle >= workers && pending <= 0 {
            stop = true
            cond.broadcast()
            idle -= 1
            return false
        }
        let deadline = Date().addingTimeInterval(0.05)
        while !stop && pending > 0 {
            // Spurious wakeups are fine; the caller tries to pop again.
            _ = cond.wait(until: deadline)
            break
        }
        idle -= 1
        return !stop
    }
}
