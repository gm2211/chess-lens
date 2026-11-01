import Foundation
import CryptoKit

public enum KokoroInstallPhase: Equatable, Sendable {
    case downloading(received: Int64, total: Int64)
    case verifying
    case unpacking
}

public enum KokoroInstallError: Error, Equatable, LocalizedError, Sendable {
    case offline
    case network(String)
    case server(status: Int)
    case notEnoughSpace(needed: Int64, available: Int64)
    case checksumMismatch
    case unpackFailed(String)
    case incomplete(missing: [String])
    case cancelled

    public var errorDescription: String? {
        let mb = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        return switch self {
        case .offline: "You appear to be offline. Connect to the internet and try again."
        case .network(let m): "The download failed: \(m)"
        case .server(let s): "The download server answered with an error (HTTP \(s)). Try again later."
        case .notEnoughSpace(let need, let have):
            "Not enough disk space: the voice needs about \(mb(need)) free while it installs, and \(mb(have)) is available."
        case .checksumMismatch: "The downloaded file is damaged or not the expected one (checksum mismatch), so it was deleted. Try again."
        case .unpackFailed(let m): "The voice could not be unpacked: \(m)"
        case .incomplete(let missing): "The download is missing files the voice needs (\(missing.joined(separator: ", ")))."
        case .cancelled: "The download was cancelled."
        }
    }

    /// URLSession / file-system errors as the user should see them.
    public static func from(_ error: Error) -> KokoroInstallError {
        if let e = error as? KokoroInstallError { return e }
        if error is CancellationError { return .cancelled }
        if let u = error as? URLError {
            switch u.code {
            case .cancelled: return .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut:
                return .offline
            case .cannotWriteToFile: return .notEnoughSpace(needed: KokoroInstaller.spaceNeeded, available: 0)
            default: return .network(u.localizedDescription)
            }
        }
        let ns = error as NSError
        if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
            || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)) {
            return .notEnoughSpace(needed: KokoroInstaller.spaceNeeded, available: 0)
        }
        return .network(ns.localizedDescription)
    }
}

/// Downloads the Kokoro archive, checks its SHA-256, unpacks only the files the voice needs with /usr/bin/tar
/// (a child process inherits the App Sandbox and only touches the app's own container) and moves the result into
/// place in one step. Any failure or cancellation leaves no partial files behind.
public struct KokoroInstaller: Sendable {
    public let asset: KokoroAsset
    public let store: KokoroStore

    /// Archive + unpacked model + 50 MB headroom.
    public static let spaceNeeded: Int64 = KokoroAsset.v1_0.size + KokoroAsset.installedSize + 50_000_000

    public init(asset: KokoroAsset = .v1_0, store: KokoroStore = .standard) {
        self.asset = asset; self.store = store
    }

    /// Installs the model and returns its size on disk. `progress` is called from background threads.
    @discardableResult
    public func install(progress: @escaping @Sendable (KokoroInstallPhase) -> Void = { _ in }) async throws -> Int64 {
        let fm = FileManager.default
        let id = UUID().uuidString
        let archive = store.root.appendingPathComponent(".kokoro-download-\(id).tar.bz2")
        let staging = store.root.appendingPathComponent(".kokoro-unpack-\(id)", isDirectory: true)
        defer { try? fm.removeItem(at: archive); try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: store.root, withIntermediateDirectories: true)
            store.cleanLeftovers()
            if let free = store.availableCapacity(), free < Self.spaceNeeded {
                throw KokoroInstallError.notEnoughSpace(needed: Self.spaceNeeded, available: free)
            }
            try await download(to: archive, progress: progress)
            try Task.checkCancellation()
            progress(.verifying)
            guard try await Self.sha256(of: archive) == asset.sha256 else { throw KokoroInstallError.checksumMismatch }
            try Task.checkCancellation()
            progress(.unpacking)
            try await unpack(archive, into: staging)
            try Task.checkCancellation()
            let dest = store.directory
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: staging, to: dest)
            return KokoroStore.diskUsage(dest)
        } catch {
            throw KokoroInstallError.from(error)
        }
    }

    private func download(to file: URL, progress: @escaping @Sendable (KokoroInstallPhase) -> Void) async throws {
        let expected = asset.size
        progress(.downloading(received: 0, total: expected))
        let response = try await Downloader(destination: file) { got, total in
            progress(.downloading(received: got, total: total > 0 ? total : expected))
        }.run(asset.url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw KokoroInstallError.server(status: http.statusCode) }
    }

    /// Unpacks the needed members (archive root stripped), drops the non-English espeak-ng dictionaries and checks
    /// that everything KokoroEngine loads is there, then writes the finished-install marker.
    func unpack(_ archive: URL, into dir: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let members = KokoroFiles.extracted.map { "\(asset.root)/\($0)" }
        try await Self.run("/usr/bin/tar", ["-xjf", archive.path, "-C", dir.path, "--strip-components", "1"] + members)
        let data = dir.appendingPathComponent("espeak-ng-data")
        for name in (try? fm.contentsOfDirectory(atPath: data.path)) ?? [] where name.hasSuffix("_dict") && name != "en_dict" {
            try? fm.removeItem(at: data.appendingPathComponent(name))
        }
        let missing = KokoroStore.missingFiles(dir)
        guard missing.isEmpty else { throw KokoroInstallError.incomplete(missing: missing) }
        try "\(asset.root) \(asset.sha256)\n".write(to: dir.appendingPathComponent(KokoroFiles.marker), atomically: true, encoding: .utf8)
    }

    /// Runs a tool to completion (terminated if the task is cancelled); a non-zero exit throws with its stderr.
    static func run(_ tool: String, _ args: [String]) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let errFile = FileManager.default.temporaryDirectory.appendingPathComponent("kokoro-tar-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errFile) }
        let errHandle = try FileHandle(forWritingTo: errFile)
        defer { try? errHandle.close() }
        p.standardError = errHandle
        p.standardOutput = FileHandle.nullDevice
        let box = ProcessBox(p)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int32, Error>) in
                p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
                do { try p.run() } catch { p.terminationHandler = nil; c.resume(throwing: KokoroInstallError.unpackFailed(error.localizedDescription)) }
            }
        } onCancel: { box.terminate() }
        try Task.checkCancellation()
        guard status == 0 else {
            let msg = (try? String(contentsOf: errFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if msg.contains("No space left") { throw KokoroInstallError.notEnoughSpace(needed: spaceNeeded, available: 0) }
            throw KokoroInstallError.unpackFailed(msg.isEmpty ? "tar exited with status \(status)" : String(msg.prefix(300)))
        }
    }

    /// Streams the file through SHA-256 off the caller's thread. Lowercase hex.
    public static func sha256(of file: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let h = try FileHandle(forReadingFrom: file)
            defer { try? h.close() }
            var hasher = SHA256()
            while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ p: Process) { process = p }
    func terminate() { if process.isRunning { process.terminate() } }
}

/// One download task on its own session, so the delegate gets byte counts (the async `download(from:delegate:)`
/// does not report them). The file is moved to `destination` as soon as URLSession hands it over.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let report: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URLResponse?, Error>?
    private var moveError: Error?
    private var last: Int64 = 0

    init(destination: URL, report: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination; self.report = report
    }

    func run(_ url: URL) async throws -> URLResponse? {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                lock.withLock { continuation = c }
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    /// At most every 512 KB.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let send = lock.withLock {
            guard totalBytesWritten - last >= 512 << 10 || totalBytesWritten == totalBytesExpectedToWrite else { return false }
            last = totalBytesWritten
            return true
        }
        if send { report(totalBytesWritten, totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do { try FileManager.default.moveItem(at: location, to: destination) } catch { lock.withLock { moveError = error } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (c, moved) = lock.withLock { () -> (CheckedContinuation<URLResponse?, Error>?, Error?) in
            defer { continuation = nil }
            return (continuation, moveError)
        }
        if let error = error ?? moved { c?.resume(throwing: error) } else { c?.resume(returning: task.response) }
    }
}
