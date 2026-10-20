import Foundation

@MainActor public protocol Cancellation: AnyObject {
    func cancel()
}

@MainActor public protocol Scheduler {
    func schedule(after seconds: TimeInterval, action: @escaping @MainActor () -> Void) -> Cancellation
}

@MainActor public struct TaskScheduler: Scheduler {
    public init() {}

    public func schedule(after seconds: TimeInterval, action: @escaping @MainActor () -> Void) -> Cancellation {
        let task = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
        return TaskCancellation(task: task)
    }
}

@MainActor private final class TaskCancellation: Cancellation {
    let task: Task<Void, Never>
    init(task: Task<Void, Never>) { self.task = task }
    func cancel() { task.cancel() }
}
