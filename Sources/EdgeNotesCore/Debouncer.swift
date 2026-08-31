import Foundation

public final class Debouncer {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private var workItem: DispatchWorkItem?
    private var pending: (() -> Void)?

    public init(delay: TimeInterval, queue: DispatchQueue = .main) {
        self.delay = delay
        self.queue = queue
    }

    public func call(_ action: @escaping () -> Void) {
        workItem?.cancel()
        pending = action
        let item = DispatchWorkItem { [weak self] in
            self?.pending = nil
            action()
        }
        workItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    public func cancel() {
        workItem?.cancel()
        workItem = nil
        pending = nil
    }

    public func flush() {
        guard let action = pending else { return }
        workItem?.cancel()
        workItem = nil
        pending = nil
        action()
    }
}
