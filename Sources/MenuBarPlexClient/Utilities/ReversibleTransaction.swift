import Foundation

@MainActor
final class ReversibleTransaction {
    private(set) var label: String
    private var rollbackSteps: [() -> Void] = []
    private var isCommitted = false

    init(label: String) {
        self.label = label
    }

    func perform(_ apply: () -> Void, rollback: @escaping () -> Void = {}) {
        apply()
        rollbackSteps.append(rollback)
    }

    func addRollback(_ rollback: @escaping () -> Void) {
        rollbackSteps.append(rollback)
    }

    func commit() {
        isCommitted = true
        rollbackSteps.removeAll()
    }

    func rollback() {
        guard !isCommitted else { return }
        let steps = rollbackSteps.reversed()
        rollbackSteps.removeAll()
        for step in steps {
            step()
        }
    }
}

@MainActor
func withReversibleTransaction(
    _ label: String,
    _ operation: (ReversibleTransaction) async throws -> Void
) async throws {
    let transaction = ReversibleTransaction(label: label)
    do {
        try await operation(transaction)
        transaction.commit()
    } catch {
        transaction.rollback()
        throw error
    }
}
