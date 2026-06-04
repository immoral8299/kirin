import Foundation

@MainActor
enum MinimumDurationTask {
    static func run<Value>(
        minimumDuration: TimeInterval,
        operation: () async throws -> Value
    ) async throws -> Value {
        let startedAt = Date()

        do {
            let value = try await operation()
            await waitIfNeeded(since: startedAt, minimumDuration: minimumDuration)
            return value
        } catch {
            await waitIfNeeded(since: startedAt, minimumDuration: minimumDuration)
            throw error
        }
    }

    private static func waitIfNeeded(since startDate: Date, minimumDuration: TimeInterval) async {
        let remainingDuration = minimumDuration - Date().timeIntervalSince(startDate)
        guard remainingDuration > 0 else { return }
        try? await Task.sleep(for: .seconds(remainingDuration))
    }
}
