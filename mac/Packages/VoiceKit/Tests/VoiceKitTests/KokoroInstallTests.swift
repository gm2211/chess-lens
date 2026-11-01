import Foundation
import Testing
@testable import VoiceKit

/// A scratch folder per test, removed afterwards.
private final class Scratch {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("voicekit-\(UUID().uuidString)", isDirectory: true)
    init() { try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// A small stand-in for kokoro-multi-lang-v1_0.tar.bz2 with the same layout (including files the install skips).
private func fakeArchive(in s: Scratch, root: String = "kokoro-multi-lang-v1_0", omit: Set<String> = []) async throws -> (URL, KokoroAsset) {
    let fm = FileManager.default
    let src = s.url.appendingPathComponent("src/\(root)", isDirectory: true)
    let files = ["model.onnx", "voices.bin", "tokens.txt", "lexicon-us-en.txt", "lexicon-gb-en.txt", "LICENSE", "README.md",
                 "lexicon-zh.txt", "date-zh.fst", "dict/jieba.dict.utf8", "espeak-ng-data/phontab", "espeak-ng-data/en_dict",
                 "espeak-ng-data/fr_dict", "espeak-ng-data/voices/!v/m1"]
    for f in files where !omit.contains(f) {
        let u = src.appendingPathComponent(f)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: UInt8(f.count), count: 4096).write(to: u)
    }
    let archive = s.url.appendingPathComponent("kokoro.tar.bz2")
    try await KokoroInstaller.run("/usr/bin/tar", ["-cjf", archive.path, "-C", s.url.appendingPathComponent("src").path, root])
    let size = (try fm.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? 0
    let asset = KokoroAsset(url: archive, sha256: try await KokoroInstaller.sha256(of: archive), size: size, root: "kokoro-multi-lang-v1_0")
    return (archive, asset)
}

private func leftovers(_ store: KokoroStore) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? []).filter { $0.hasPrefix(".kokoro-") }
}

@Test func installsOnlyTheNeededFiles() async throws {
    let s = Scratch()
    let (_, asset) = try await fakeArchive(in: s)
    let store = KokoroStore(root: s.url.appendingPathComponent("Voices"))
    #expect(store.status == .notInstalled)

    let phases = PhaseLog()
    let bytes = try await KokoroInstaller(asset: asset, store: store).install { phases.add($0) }
    #expect(bytes > 0)
    #expect(store.status == .installed(bytes: bytes))
    let dir = store.directory
    let fm = FileManager.default
    for f in KokoroFiles.required + ["LICENSE", "VERSION", "espeak-ng-data/voices/!v/m1"] {
        #expect(fm.fileExists(atPath: dir.appendingPathComponent(f).path), "missing \(f)")
    }
    for f in ["README.md", "lexicon-zh.txt", "date-zh.fst", "dict", "espeak-ng-data/fr_dict", "kokoro-multi-lang-v1_0"] {
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent(f).path), "unexpected \(f)")
    }
    #expect(leftovers(store).isEmpty)
    let seen = phases.all
    #expect(seen.contains(.verifying) && seen.contains(.unpacking))
    #expect(seen.first.map { if case .downloading = $0 { true } else { false } } == true)
}

@Test func reinstallReplacesAndRemoveDeletes() async throws {
    let s = Scratch()
    let (_, asset) = try await fakeArchive(in: s)
    let store = KokoroStore(root: s.url.appendingPathComponent("Voices"))
    try await KokoroInstaller(asset: asset, store: store).install()
    try "stale".write(to: store.directory.appendingPathComponent("stale.txt"), atomically: true, encoding: .utf8)
    try await KokoroInstaller(asset: asset, store: store).install()
    #expect(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("stale.txt").path))
    #expect(store.isInstalled)

    try store.remove()
    #expect(store.status == .notInstalled)
    #expect(!FileManager.default.fileExists(atPath: store.directory.path))
}

@Test func checksumMismatchInstallsNothing() async throws {
    let s = Scratch()
    var (_, asset) = try await fakeArchive(in: s)
    asset.sha256 = String(repeating: "0", count: 64)
    let store = KokoroStore(root: s.url.appendingPathComponent("Voices"))
    await #expect(throws: KokoroInstallError.checksumMismatch) { try await KokoroInstaller(asset: asset, store: store).install() }
    #expect(store.status == .notInstalled)
    #expect(leftovers(store).isEmpty)
}

@Test func archiveMissingAFileIsRejected() async throws {
    let s = Scratch()
    let (_, asset) = try await fakeArchive(in: s, omit: ["voices.bin"])
    let store = KokoroStore(root: s.url.appendingPathComponent("Voices"))
    do {
        try await KokoroInstaller(asset: asset, store: store).install()
        Issue.record("install should fail")
    } catch let e as KokoroInstallError {
        // bsdtar reports the absent member itself; either way nothing is installed.
        switch e {
        case .unpackFailed(let m): #expect(m.contains("voices.bin"))
        case .incomplete(let missing): #expect(missing == ["voices.bin"])
        default: Issue.record("unexpected \(e)")
        }
    }
    #expect(store.status == .notInstalled)
    #expect(leftovers(store).isEmpty)
}

@Test func missingSourceIsANetworkError() async throws {
    let s = Scratch()
    let asset = KokoroAsset(url: s.url.appendingPathComponent("nope.tar.bz2"), sha256: "00", size: 1, root: "x")
    let store = KokoroStore(root: s.url.appendingPathComponent("Voices"))
    await #expect(throws: KokoroInstallError.self) { try await KokoroInstaller(asset: asset, store: store).install() }
    #expect(store.status == .notInstalled)
}

@Test func cancellingStopsTheInstall() async throws {
    let s = Scratch()
    let (_, asset) = try await fakeArchive(in: s)
    let store = KokoroStore(root: s.url.appendingPathComponent("Voices"))
    let task = Task { try await KokoroInstaller(asset: asset, store: store).install() }
    task.cancel()
    await #expect(throws: KokoroInstallError.cancelled) { try await task.value }
    #expect(store.status == .notInstalled)
    #expect(leftovers(store).isEmpty)
}

@Test func statusNeedsEveryFileAndTheMarker() throws {
    let s = Scratch()
    let store = KokoroStore(root: s.url)
    let fm = FileManager.default
    for f in KokoroFiles.required {
        let u = store.directory.appendingPathComponent(f)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: u)
    }
    #expect(store.status == .notInstalled)                 // no VERSION marker: an interrupted install
    try Data().write(to: store.directory.appendingPathComponent(KokoroFiles.marker))
    #expect(store.isInstalled)
    try fm.removeItem(at: store.directory.appendingPathComponent("espeak-ng-data/en_dict"))
    #expect(store.status == .notInstalled)
    #expect(KokoroStore.missingFiles(store.directory) == ["espeak-ng-data/en_dict"])
}

@Test func leftoversAreCleaned() throws {
    let s = Scratch()
    let store = KokoroStore(root: s.url)
    try Data([1]).write(to: s.url.appendingPathComponent(".kokoro-download-x.tar.bz2"))
    try FileManager.default.createDirectory(at: s.url.appendingPathComponent(".kokoro-unpack-x"), withIntermediateDirectories: true)
    try Data([1]).write(to: s.url.appendingPathComponent("keep.txt"))
    store.cleanLeftovers()
    #expect(leftovers(store).isEmpty)
    #expect(FileManager.default.fileExists(atPath: s.url.appendingPathComponent("keep.txt").path))
}

@Test func errorsReadClearly() {
    #expect(KokoroInstallError.from(URLError(.notConnectedToInternet)) == .offline)
    #expect(KokoroInstallError.from(URLError(.timedOut)) == .offline)
    #expect(KokoroInstallError.from(URLError(.cancelled)) == .cancelled)
    #expect(KokoroInstallError.from(CancellationError()) == .cancelled)
    if case .notEnoughSpace = KokoroInstallError.from(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))) {} else { Issue.record("ENOSPC") }
    if case .notEnoughSpace = KokoroInstallError.from(CocoaError(.fileWriteOutOfSpace)) {} else { Issue.record("out of space") }
    #expect(KokoroInstallError.offline.errorDescription?.contains("offline") == true)
    #expect(KokoroInstallError.notEnoughSpace(needed: 800_000_000, available: 100_000_000).errorDescription?.contains("800") == true)
    #expect(KokoroInstallError.checksumMismatch.errorDescription?.contains("checksum") == true)
}

@Test func pinnedAssetMatchesFetchScript() {
    #expect(KokoroAsset.v1_0.sha256 == "60703707bc05ccd48d60e1eb723f38b07d6e474795a0b6a588d7220400e0f7a4")
    #expect(KokoroAsset.v1_0.url.lastPathComponent == "kokoro-multi-lang-v1_0.tar.bz2")
    #expect(KokoroInstaller.spaceNeeded > KokoroAsset.v1_0.size + KokoroAsset.installedSize)
}

private final class PhaseLog: @unchecked Sendable {
    private var phases: [KokoroInstallPhase] = []
    private let lock = NSLock()
    func add(_ p: KokoroInstallPhase) { lock.lock(); phases.append(p); lock.unlock() }
    var all: [KokoroInstallPhase] { lock.lock(); defer { lock.unlock() }; return phases }
}
