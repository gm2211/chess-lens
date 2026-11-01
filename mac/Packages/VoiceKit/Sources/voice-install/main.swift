import Foundation
import VoiceKit

// Headless run of the app's Kokoro install path (download, SHA-256 check, unpack, atomic move):
//   voice-install <archive path or URL> <dest-root> [sha256]
// A local path is fetched through URLSession as a file:// URL, so the same code path as the app's download runs.
// The model ends up in <dest-root>/Kokoro. Prints phases and the installed size; exit 0 on success.
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: voice-install <archive path or URL> <dest-root> [sha256]"); exit(2) }
let source = args[1].contains("://") ? URL(string: args[1])! : URL(fileURLWithPath: args[1])
var asset = KokoroAsset.v1_0
asset.url = source
if args.count > 3 { asset.sha256 = args[3].lowercased() }
if source.isFileURL, let size = (try? FileManager.default.attributesOfItem(atPath: source.path))?[.size] as? Int64 { asset.size = size }
let store = KokoroStore(root: URL(fileURLWithPath: args[2], isDirectory: true))

let lastPrinted = Mutex(-1)
let start = Date()
do {
    let bytes = try await KokoroInstaller(asset: asset, store: store).install { phase in
        switch phase {
        case .downloading(let got, let total):
            let pct = total > 0 ? Int(got * 100 / total) : 0
            if lastPrinted.swap(pct) != pct, pct % 10 == 0 { print("downloading \(pct)%") }
        case .verifying: print("verifying sha256")
        case .unpacking: print("unpacking")
        }
    }
    print(String(format: "installed %@ in %@ (%.1f s)", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                 store.directory.path, Date().timeIntervalSince(start)))
    print("status: \(store.status)")
    exit(store.isInstalled ? 0 : 1)
} catch {
    print("FAILED: \(error.localizedDescription) [\(error)]")
    exit(1)
}

final class Mutex<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func swap(_ v: T) -> T { lock.lock(); defer { lock.unlock() }; let old = value; value = v; return old }
}
