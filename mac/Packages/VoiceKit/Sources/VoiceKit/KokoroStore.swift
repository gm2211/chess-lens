import Foundation

/// The downloadable Kokoro model: sherpa-onnx's kokoro-multi-lang-v1_0 release asset, pinned by SHA-256
/// (the same file mac/scripts/fetch-kokoro.sh fetches for development).
public struct KokoroAsset: Sendable, Equatable {
    public var url: URL
    public var sha256: String
    /// Bytes of the archive, for progress when the server sends no length and for the free-space check.
    public var size: Int64
    /// The folder every file sits under in the archive.
    public var root: String

    public init(url: URL, sha256: String, size: Int64, root: String) {
        self.url = url; self.sha256 = sha256.lowercased(); self.size = size; self.root = root
    }

    public static let v1_0 = KokoroAsset(
        url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_0.tar.bz2")!,
        sha256: "60703707bc05ccd48d60e1eb723f38b07d6e474795a0b6a588d7220400e0f7a4",
        size: 349_886_476,
        root: "kokoro-multi-lang-v1_0")

    /// About what the unpacked English model takes (fp32 model.onnx is 310 MB of it; 379 MB allocated on APFS).
    public static let installedSize: Int64 = 380_000_000
}

/// The files of an installed Kokoro model, relative to its folder. What KokoroEngine needs, plus the license.
public enum KokoroFiles {
    public static let required = ["model.onnx", "voices.bin", "tokens.txt", "lexicon-us-en.txt", "lexicon-gb-en.txt",
                                  "espeak-ng-data/phontab", "espeak-ng-data/en_dict"]
    /// Archive members extracted (folders take their contents). The rest (Chinese lexicons and FSTs, README) is skipped.
    public static let extracted = ["model.onnx", "voices.bin", "tokens.txt", "lexicon-us-en.txt", "lexicon-gb-en.txt",
                                   "LICENSE", "espeak-ng-data"]
    public static let license = "LICENSE"
    /// Marks a finished install (written last); its content names the asset.
    public static let marker = "VERSION"
}

/// Where the downloaded model lives: <root>/Kokoro, e.g. ~/Library/Containers/<app>/Data/Library/Application Support/
/// Étude/Voices/Kokoro. Downloads and unpacking happen next to it (<root>/.kokoro-*) so the final move is atomic.
public struct KokoroStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    /// Application Support/Étude/Voices (inside the app's container when sandboxed).
    public static var standard: KokoroStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return KokoroStore(root: base.appendingPathComponent("Étude", isDirectory: true).appendingPathComponent("Voices", isDirectory: true))
    }

    public var directory: URL { root.appendingPathComponent("Kokoro", isDirectory: true) }

    public enum Status: Equatable, Sendable {
        case notInstalled
        case installed(bytes: Int64)
    }

    /// Installed only when the finished-install marker and every needed file are there.
    public var status: Status {
        Self.isComplete(directory) ? .installed(bytes: Self.diskUsage(directory)) : .notInstalled
    }
    public var isInstalled: Bool { Self.isComplete(directory) }

    public static func isComplete(_ dir: URL) -> Bool {
        missingFiles(dir).isEmpty && FileManager.default.fileExists(atPath: dir.appendingPathComponent(KokoroFiles.marker).path)
    }

    public static func missingFiles(_ dir: URL) -> [String] {
        KokoroFiles.required.filter { !FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    /// Allocated bytes of everything under `dir`.
    public static func diskUsage(_ dir: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Deletes the model and anything a cancelled or crashed install left behind.
    public func remove() throws {
        cleanLeftovers()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    /// Partial downloads and half-unpacked folders (`.kokoro-*`).
    public func cleanLeftovers() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix(".kokoro-") {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
    }

    /// Free bytes on the store's volume, as macOS counts space for user-requested downloads.
    public func availableCapacity() -> Int64? {
        var probe = root
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        let v = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = v?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return v?.volumeAvailableCapacity.map(Int64.init)
    }
}
