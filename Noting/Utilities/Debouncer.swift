import Foundation

@MainActor
final class Debouncer {
    private var task: Task<Void, Never>?

    func debounce(delay: Duration = .milliseconds(300), action: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
