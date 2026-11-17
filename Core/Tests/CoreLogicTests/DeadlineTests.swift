import XCTest
@testable import CoreLogic

final class DeadlineTests: XCTestCase {
    private typealias Deadline = CoreLogic.Deadline

    private func work(for duration: Duration) -> Task<String, Never> {
        Task {
            do {
                try await Task.sleep(for: duration)
                return "finished"
            } catch {
                return "cancelled"
            }
        }
    }

    func testWorkDoneInTimeGivesItsValue() async {
        let value = await Deadline.value(of: work(for: .milliseconds(20)), by: .now + .seconds(5))
        XCTAssertEqual(value, "finished")
    }

    // The Shortcuts action answers when its time is up; the bank sync it started carries on.
    func testWorkThatOverrunsIsLeftRunning() async {
        let clock = ContinuousClock()
        let start = clock.now
        let task = work(for: .milliseconds(600))

        let value = await Deadline.value(of: task, by: start + .milliseconds(100))

        XCTAssertNil(value)
        XCTAssertLessThan(clock.now - start, .milliseconds(400), "answers at the deadline, not when the work ends")
        let finished = await task.value
        XCTAssertEqual(finished, "finished", "the work isn't cancelled")
    }

    func testADeadlineAlreadyPastGivesNothing() async {
        let value = await Deadline.value(of: work(for: .milliseconds(200)), by: .now - .seconds(1))
        XCTAssertNil(value)
    }
}
