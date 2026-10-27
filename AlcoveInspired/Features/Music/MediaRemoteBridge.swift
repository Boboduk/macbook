import Foundation
import IslandCore
import os.log

/// Runs the `NowPlayingHelper` library and relays its line protocol.
///
/// macOS exposes the system-wide "Now Playing" session only through the
/// private MediaRemote framework, which since macOS 15.4 refuses calls from
/// ordinary third-party apps. The accepted work-around (used by several
/// open-source menu-bar players) is to let a *system* binary load the code:
/// AlcoveInspired launches `/usr/bin/perl`, which loads
/// `libNowPlayingHelper.dylib` with `DynaLoader` and calls its `nph_run`
/// entry point. Perl is allowed to load unsigned bundles (that is how every
/// CPAN XS module works), so the ad-hoc-signed helper loads where the app
/// itself could not.
///
/// The helper prints one JSON object per line on stdout and reads one command
/// per line on stdin (see `MediaRemoteParser` / `MediaRemoteCommand`). If the
/// helper cannot be found or started, or MediaRemote is unavailable, the
/// bridge reports `.error` and `MusicController` falls back to the AppleScript
/// players.
@MainActor
final class MediaRemoteBridge {
    /// Parsed messages from the helper, delivered on the main actor.
    var onMessage: ((MediaRemoteMessage) -> Void)?

    private let dylibName = "libNowPlayingHelper.dylib"
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AlcoveInspired", category: "MediaRemote")

    private var process: Process?
    private var stdinPipe: Pipe?
    private var buffer = Data()
    private var isStopping = false
    private var restartCount = 0
    private let maxRestarts = 3
    private var restartWork: DispatchWorkItem?

    private static let newline = UInt8(ascii: "\n")

    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Lifecycle

    func start() {
        guard process == nil else { return }
        isStopping = false
        launch()
    }

    func stop() {
        isStopping = true
        restartWork?.cancel()
        restartWork = nil
        restartCount = 0
        teardownProcess()
    }

    func send(_ command: MediaRemoteCommand) {
        guard let handle = stdinPipe?.fileHandleForWriting else { return }
        var line = command.line
        line.append("\n")
        guard let data = line.data(using: .utf8) else { return }
        // The pipe can be closed if the helper just died; writing then raises
        // SIGPIPE-as-exception, so guard it.
        do {
            try handle.write(contentsOf: data)
        } catch {
            log.debug("command write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Launch

    private func launch() {
        guard let dylibURL = preparedDylibURL() else {
            onMessage?(.error("NowPlayingHelper is missing from the app bundle"))
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.loaderScript, dylibURL.path]

        let stdout = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin

        buffer.removeAll(keepingCapacity: true)
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.ingest(chunk) }
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.processTerminated() }
        }

        do {
            try process.run()
        } catch {
            log.error("failed to launch perl: \(error.localizedDescription, privacy: .public)")
            onMessage?(.error("Could not start the Now Playing helper"))
            return
        }

        self.process = process
        self.stdinPipe = stdin
        log.debug("NowPlayingHelper started")
    }

    private func ingest(_ chunk: Data) {
        buffer.append(chunk)
        while let index = buffer.firstIndex(of: Self.newline) {
            let line = buffer.subdata(in: buffer.startIndex..<index)
            buffer.removeSubrange(buffer.startIndex...index)
            guard !line.isEmpty else { continue }
            if let message = MediaRemoteParser.parse(line: line) {
                if message == .ready { restartCount = 0 }
                onMessage?(message)
            }
        }
    }

    private func processTerminated() {
        teardownProcess()
        guard !isStopping else { return }
        guard restartCount < maxRestarts else {
            log.error("NowPlayingHelper stopped repeatedly; giving up")
            onMessage?(.error("The Now Playing helper stopped unexpectedly"))
            return
        }
        restartCount += 1
        let delay = Double(restartCount) * 0.8
        log.debug("relaunching NowPlayingHelper in \(delay, privacy: .public)s (attempt \(self.restartCount, privacy: .public))")
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.launch() }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func teardownProcess() {
        if let stdout = (process?.standardOutput as? Pipe)?.fileHandleForReading {
            stdout.readabilityHandler = nil
        }
        if let process, process.isRunning {
            process.terminationHandler = nil
            // Closing stdin makes the helper reach EOF and exit; terminate is
            // the backstop if it is wedged.
            try? stdinPipe?.fileHandleForWriting.close()
            process.terminate()
        } else {
            try? stdinPipe?.fileHandleForWriting.close()
        }
        stdinPipe = nil
        process = nil
        buffer.removeAll(keepingCapacity: false)
    }

    // MARK: - Dylib

    /// Copies the helper out of the (possibly read-only or translocated) app
    /// bundle into Application Support, writing a fresh file so no quarantine
    /// flag is inherited. Returns the usable path, or `nil` if the helper is
    /// not bundled (e.g. a plain `swift run` during development).
    private func preparedDylibURL() -> URL? {
        guard let source = bundledDylibURL() else { return nil }
        let fileManager = FileManager.default
        guard let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return source }

        let folder = appSupport.appendingPathComponent("AlcoveInspired", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(dylibName)

        guard let data = try? Data(contentsOf: source) else { return source }
        // Rewrite only when the bytes differ, so we do not thrash the disk.
        let existing = try? Data(contentsOf: destination)
        if existing != data {
            do {
                try data.write(to: destination, options: .atomic)
            } catch {
                log.error("could not stage helper: \(error.localizedDescription, privacy: .public)")
                return source
            }
        }
        return destination
    }

    private func bundledDylibURL() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let frameworks = Bundle.main.privateFrameworksURL {
            candidates.append(frameworks.appendingPathComponent(dylibName))
        }
        if let resource = Bundle.main.url(forResource: "libNowPlayingHelper", withExtension: "dylib") {
            candidates.append(resource)
        }
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    /// Perl program that loads the helper and transfers control to it.
    private static let loaderScript = """
    use DynaLoader;
    my $path = $ARGV[0];
    my $lib = DynaLoader::dl_load_file($path, 0) or die "dl_load_file failed: $path";
    my $sym = DynaLoader::dl_find_symbol($lib, "nph_run") or die "nph_run not found";
    my $run = DynaLoader::dl_install_xsub("nph_run", $sym);
    $run->();
    """
}
