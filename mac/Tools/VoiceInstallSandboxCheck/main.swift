import Foundation

// Runs the app's Kokoro install path (Packages/VoiceKit: URLSession download, SHA-256 check, /usr/bin/tar unpack,
// atomic move) inside the App Sandbox, as scripts/check-voice-install-sandbox.sh sets it up. It installs into a
// scratch folder in the container's tmp (not the real Application Support/Étude/Voices) and deletes it afterwards.
//   Etude <archive URL>
let args = CommandLine.arguments
guard args.count >= 2, let url = URL(string: args[1]) else { print("usage: Etude <archive URL>"); exit(2) }
print("sandboxed: \(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)")
print("app's real store: \(KokoroStore.standard.directory.path)")

var asset = KokoroAsset.v1_0
asset.url = url
let store = KokoroStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("voice-install-check", isDirectory: true))
defer { try? FileManager.default.removeItem(at: store.root) }

final class Log: @unchecked Sendable {
    var updates = 0, last = -25
    let lock = NSLock()
    func download(_ got: Int64, _ total: Int64) {
        lock.lock(); defer { lock.unlock() }
        updates += 1
        let pct = Int(got * 100 / max(total, 1))
        if pct / 25 != last / 25 { last = pct; print("downloading \(pct)% (\(got) of \(total) bytes)") }
    }
}
let log = Log()
let start = Date()
do {
    let bytes = try await KokoroInstaller(asset: asset, store: store).install { phase in
        switch phase {
        case .downloading(let got, let total): log.download(got, total)
        case .verifying: print("verifying sha256 (\(log.updates) progress updates)")
        case .unpacking: print("unpacking with /usr/bin/tar")
        }
    }
    print(String(format: "installed %lld bytes into %@ in %.1f s", bytes, store.directory.path, Date().timeIntervalSince(start)))
    let fm = FileManager.default
    for f in (try fm.contentsOfDirectory(atPath: store.directory.path)).sorted() {
        let size = (try? fm.attributesOfItem(atPath: store.directory.appendingPathComponent(f).path)[.size] as? Int64) ?? 0
        print("  \(f) \(size)")
    }
    print("espeak-ng-data: \((try fm.contentsOfDirectory(atPath: store.directory.appendingPathComponent("espeak-ng-data").path)).sorted().joined(separator: " "))")
    try store.remove()
    print("removed: \(store.status == .notInstalled)")
    // A missing file on the server must surface as an HTTP error and leave nothing behind.
    var missing = asset
    missing.url = url.deletingLastPathComponent().appendingPathComponent("missing.tar.bz2")
    do { try await KokoroInstaller(asset: missing, store: store).install(); print("404 case: unexpectedly succeeded") }
    catch { print("404 case: \(error.localizedDescription) (installed: \(store.isInstalled))") }
    print(store.status == .notInstalled && log.updates > 0 ? "SANDBOX INSTALL OK" : "SANDBOX INSTALL INCOMPLETE")
    exit(log.updates > 0 ? 0 : 1)
} catch {
    print("FAILED: \(error.localizedDescription) [\(error)]")
    exit(1)
}
