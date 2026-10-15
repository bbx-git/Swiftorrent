import Testing
@testable import SwiftorrentCore

@Suite struct ConnectionBudgetTests {
    @Test func neverHandsOutMoreThanTheLimit() async throws {
        let budget = ConnectionBudget(limit: 2)
        try await budget.acquire()
        try await budget.acquire()
        #expect(budget.inUse == 2)

        let third = Task { try await budget.acquire() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(budget.inUse == 2)
        #expect(budget.waiting == 1)

        budget.release()
        try await third.value
        #expect(budget.inUse == 2)
        #expect(budget.waiting == 0)
    }

    @Test func waitersAreServedInArrivalOrder() async throws {
        let budget = ConnectionBudget(limit: 1)
        try await budget.acquire()
        let order = OrderBox()
        var tasks: [Task<Void, Error>] = []
        for name in ["a", "b", "c"] {
            tasks.append(Task {
                try await budget.acquire()
                await order.append(name)
                budget.release()
            })
            try await Task.sleep(for: .milliseconds(30))
        }
        budget.release()
        for task in tasks { try await task.value }
        #expect(await order.items == ["a", "b", "c"])
    }

    @Test func cancelledWaiterLeavesTheQueueAndHoldsNothing() async throws {
        let budget = ConnectionBudget(limit: 1)
        try await budget.acquire()
        let waiter = Task { try await budget.acquire() }
        try await Task.sleep(for: .milliseconds(100))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(budget.waiting == 0)
        #expect(budget.inUse == 1)
        budget.release()
        #expect(budget.inUse == 0)
    }
}

private actor OrderBox {
    var items: [String] = []
    func append(_ item: String) { items.append(item) }
}
