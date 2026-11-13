import Foundation

/// Tells when something in a folder is made, replaced, renamed or removed, so that whoever shows
/// what is in it does not have to look every second. The app watches its support folder this
/// way: the state file, the configuration and the pause file are all written or replaced there.
/// A file that is rewritten in place is not reported, only one that is replaced (an atomic
/// write) or made new. What is in the folders inside it is not watched.
///
/// The folder need not be there yet, and it may go away and come back: meanwhile the nearest
/// folder above it is watched, where it will show up. Watching ends when the watcher is let go.
public final class FolderWatcher {
    private let folder: URL
    private let queue: DispatchQueue
    private let changed: () -> Void
    private var source: DispatchSourceFileSystemObject?
    /// False while the folder is not there and a folder above it is watched instead.
    private var found = false
    private var reporting = false

    /// `changed` is called on `queue`, which has to be a serial one.
    public init(_ folder: URL, queue: DispatchQueue = .main, changed: @escaping () -> Void) {
        self.folder = folder
        self.queue = queue
        self.changed = changed
        watch()
    }

    deinit { source?.cancel() }

    /// Watches the folder, or the nearest folder above it that is there.
    private func watch() {
        source?.cancel()
        source = nil
        found = false
        var path = folder.path
        var file = open(path, O_EVTONLY)
        while file < 0, path.count > 1 {
            path = (path as NSString).deletingLastPathComponent
            file = open(path, O_EVTONLY)
        }
        guard file >= 0 else { return }
        found = path == folder.path
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: file, eventMask: [.write, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self] in self?.event() }
        source.setCancelHandler { close(file) }
        self.source = source
        source.resume()
        // The folder may have been made between the look for it and the start of the watch.
        if !found {
            let now = open(folder.path, O_EVTONLY)
            if now >= 0 {
                close(now)
                queue.async { [weak self] in self?.event() }
            }
        }
    }

    private func event() {
        guard let source else { return }
        let before = found
        // The folder was made, or it was removed or renamed: watch what is there now.
        if !found || !source.data.isDisjoint(with: [.delete, .rename]) { watch() }
        if before || found { report() }
    }

    /// Calls back a moment after the change, once for changes that follow each other closely:
    /// an atomic write is two of them, the temporary file and its renaming.
    private func report() {
        guard !reporting else { return }
        reporting = true
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            reporting = false
            changed()
        }
    }
}
