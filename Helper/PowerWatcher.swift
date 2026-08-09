import Foundation

/// Notices that something moved the power settings.
///
/// Two independent kinds of source, because neither alone is enough:
///
/// - File watches on the power management preferences, for an immediate
///   reaction when another process writes them. There is more than one such
///   file — a plain one and a per-machine one — and which of them a write lands
///   in varies, so all of them are watched.
/// - A timer, because not every route into those settings goes through those
///   files, because a file can appear after we started, and because a watch can
///   be lost without saying so.
///
/// Extra callbacks are cheap by design — the enforcement pass they trigger does
/// nothing when the machine already obeys — so this errs towards checking too
/// often rather than missing a change.
final class PowerWatcher {
    private let urls: [URL]
    private let interval: TimeInterval
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "ai.pakslab.keep-mac-awake.watcher")

    private var timer: DispatchSourceTimer?
    private var fileSources: [URL: DispatchSourceFileSystemObject] = [:]
    private var running = false

    init(watching urls: [URL], every interval: TimeInterval, onChange: @escaping () -> Void) {
        self.urls = urls
        self.interval = interval
        self.onChange = onChange
    }

    /// Synchronous on purpose: once this returns, the watches are armed. Arming
    /// in the background leaves a gap in which a change goes unseen, and a
    /// missed change is the one thing this class exists to prevent.
    func start() {
        queue.sync { [self] in
            guard !running else { return }
            running = true
            startTimer()
            for url in urls { armFileWatch(url) }
        }
    }

    func stop() {
        queue.sync { [self] in
            running = false
            timer?.cancel()
            timer = nil
            for source in fileSources.values { source.cancel() }
            fileSources.removeAll()
        }
    }

    // MARK: - Sources

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Also the recovery path for watches that could not be armed
            // because the file did not exist yet.
            for url in self.urls where self.fileSources[url] == nil {
                self.armFileWatch(url)
            }
            self.onChange()
        }
        self.timer = timer
        timer.resume()
    }

    private func armFileWatch(_ url: URL) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }  // the timer retries later

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke, .link],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            self.onChange()

            // The descriptor now points at a file that is no longer at this
            // path, so this watch is deaf until it is re-opened.
            if !events.intersection([.delete, .rename, .revoke]).isEmpty {
                self.rearm(url)
            }
        }
        source.setCancelHandler { close(descriptor) }

        fileSources[url] = source
        source.resume()
    }

    /// Re-opens a path after the file behind it was replaced.
    ///
    /// The replacement is not necessarily in place yet, hence the short delay —
    /// and because we are deaf across that gap, the re-armed watch reports a
    /// change it did not see. A write that already happened is exactly what
    /// would otherwise be missed.
    private func rearm(_ url: URL) {
        fileSources.removeValue(forKey: url)?.cancel()
        guard running else { return }

        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.running, self.fileSources[url] == nil else { return }
            self.armFileWatch(url)
            self.onChange()
        }
    }
}
