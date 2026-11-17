import Foundation

extension CoreLogic {
    // A Shortcuts action has to answer within about 30 seconds, and a bank can take longer.
    public enum Deadline {
        // The task's value if it ends by the deadline, nil if time runs out first. Only the wait
        // ends: the task carries on, since it may be part-way through a bank sync.
        public static func value<T: Sendable>(
            of task: Task<T, Never>, by deadline: ContinuousClock.Instant
        ) async -> T? {
            let (first, answer) = AsyncStream.makeStream(of: T?.self)
            let ended = Task { answer.yield(await task.value) }
            let timer = Task {
                guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
                answer.yield(nil)
            }
            defer {
                ended.cancel()
                timer.cancel()
                answer.finish()
            }
            for await value in first { return value }
            return nil
        }
    }
}
