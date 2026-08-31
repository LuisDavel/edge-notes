import Foundation

public final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject
    private let fd: Int32
    private let debouncer = Debouncer(delay: 0.2, queue: .main)

    public init?(url: URL, onChange: @escaping () -> Void) {
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .link, .rename, .delete], queue: .main)
        let debouncer = self.debouncer
        source.setEventHandler {
            debouncer.call(onChange)
        }
        let fd = self.fd
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    public func stop() {
        source.cancel()
    }

    deinit {
        if !source.isCancelled { source.cancel() }
    }
}
