import Foundation
import CryptoKit

/// Serializes installs and selections. The UI never performs multi-GB I/O itself.
public actor PayloadLibrary {
    private let root: URL
    private let fm = FileManager.default
    private var state: LibraryState
    private var importing = false
    private let conditions: @Sendable () -> ImportConditions
    private let maxBytes: Int64 = 16 * 1024 * 1024 * 1024
    private let maxEntries = 100_000
    private static let dataDir = "data_sts2_windows_x86_64"
    private static let required = ["SlayTheSpire2.pck", "release_info.json",
        "\(dataDir)/sts2.dll", "\(dataDir)/sts2.deps.json",
        "\(dataDir)/sts2.runtimeconfig.json"]

    public init(root: URL, conditions: @escaping @Sendable () -> ImportConditions = { ImportConditions.system() }) throws {
        self.root = root
        self.conditions = conditions
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = root.appendingPathComponent("library.json")
        if FileManager.default.fileExists(atPath: index.path) {
            do {
                let size = try index.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 4 * 1024 * 1024 else { throw LauncherError.damagedIndex }
                let data = try Data(contentsOf: index)
                state = try JSONDecoder().decode(LibraryState.self, from: data)
                let payloadIDs = Set(state.payloads.map(\.id))
                let profileIDs = Set(state.profiles.map(\.id))
                guard state.schema == 1,
                      payloadIDs.count == state.payloads.count,
                      profileIDs.count == state.profiles.count,
                      state.profiles.allSatisfy({ payloadIDs.contains($0.payloadID) }),
                      state.selectedProfileID.map({ profileIDs.contains($0) }) ?? true
                else { throw LauncherError.damagedIndex }
            } catch { throw LauncherError.damagedIndex }
        } else { state = LibraryState() }
    }

    public func snapshot() -> LibraryState { state }

    public func select(_ profileID: UUID) throws {
        guard let profile = state.profiles.first(where: { $0.id == profileID }),
              fm.fileExists(atPath: gameURL(profile.payloadID).appendingPathComponent("SlayTheSpire2.pck").path)
        else { throw LauncherError.missingProfile }
        guard state.selectedProfileID != profileID else { return }
        var next = state
        next.selectedProfileID = profileID
        try persist(next)
    }

    /// Only accepts an already extracted folder; no executable is loaded or modified.
    /// All input is copied to private staging before metadata is trusted.
    @discardableResult
    public func importDirectory(_ source: URL) async throws -> InstalledPayload {
        // Awaiting a checkpoint makes this actor reentrant; keep one install active.
        guard !importing else { throw LauncherError.importInProgress }
        importing = true
        defer { importing = false }
        try await checkpoint()
        let staging = root.appendingPathComponent("staging/\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let game = staging.appendingPathComponent("game", isDirectory: true)
        let copied = try await copyTree(from: source, to: game)
        for path in Self.required {
            let file = game.appendingPathComponent(path)
            guard fm.fileExists(atPath: file.path),
                  try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            else { throw LauncherError.invalidPayload("缺少 \(path)") }
        }
        guard try prefix(game.appendingPathComponent("SlayTheSpire2.pck"), count: 4) == Data("GDPC".utf8)
        else { throw LauncherError.invalidPayload("PCK 文件头错误") }
        guard try prefix(game.appendingPathComponent("\(Self.dataDir)/sts2.dll"), count: 2) == Data("MZ".utf8)
        else { throw LauncherError.invalidPayload("DLL 文件头错误") }
        let releaseURL = game.appendingPathComponent("release_info.json")
        let size = try releaseURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1024 * 1024 else { throw LauncherError.invalidPayload("版本信息过大") }
        let release = try JSONDecoder().decode(ReleaseInfo.self, from: Data(contentsOf: releaseURL))
        guard !release.version.isEmpty, release.version.count <= 128,
              !release.version.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw LauncherError.invalidPayload("版本号错误") }
        guard let dllHash = copied.hashes["\(Self.dataDir)/sts2.dll"],
              let pckHash = copied.hashes["slaythespire2.pck"]
        else { throw LauncherError.invalidPayload("文件摘要缺失") }
        try await checkpoint()
        // Different versions/installs remain independent even when their labels match.
        let payload = InstalledPayload(id: UUID(), version: release.version,
            dllSHA256: dllHash, pckSHA256: pckHash, installedAt: Date(), byteCount: copied.bytes)
        let profile = LaunchProfile(id: UUID(), payloadID: payload.id, name: release.version)
        let instance = profileURL(profile.id)
        let destination = root.appendingPathComponent("payloads/\(payload.id.uuidString)", isDirectory: true)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.createDirectory(at: instance.appendingPathComponent("default/1"), withIntermediateDirectories: true)
            try fm.createDirectory(at: instance.appendingPathComponent("mods"), withIntermediateDirectories: true)
            try Task.checkCancellation()
            try fm.moveItem(at: staging, to: destination)
            var next = state
            next.payloads.append(payload)
            next.profiles.append(profile)
            next.selectedProfileID = profile.id
            try persist(next)
        } catch {
            try? fm.removeItem(at: destination)
            try? fm.removeItem(at: instance)
            throw error
        }
        return payload
    }

    public func accountRoot(for profileID: UUID) throws -> URL {
        guard state.profiles.contains(where: { $0.id == profileID }) else { throw LauncherError.missingProfile }
        return profileURL(profileID).appendingPathComponent("default/1", isDirectory: true)
    }

    private func persist(_ next: LibraryState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(next).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        state = next
    }

    private func gameURL(_ id: UUID) -> URL {
        root.appendingPathComponent("payloads/\(id.uuidString)/game", isDirectory: true)
    }
    private func profileURL(_ id: UUID) -> URL {
        root.appendingPathComponent("instances/\(id.uuidString)", isDirectory: true)
    }

    private func prefix(_ file: URL, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try handle.read(upToCount: count) ?? Data()
    }

    private func checkpoint() async throws {
        try Task.checkCancellation()
        let current = conditions()
        guard !current.shouldStop else { throw LauncherError.thermalLimited }
        if current.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: current.delayNanoseconds)
        } else {
            await Task.yield()
        }
        try Task.checkCancellation()
    }

    private struct CopyResult {
        var bytes: Int64 = 0
        var hashes: [String: String] = [:]
    }

    private func copyTree(from source: URL, to destination: URL) async throws -> CopyResult {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let sourceValues = try source.resourceValues(forKeys: keys)
        guard sourceValues.isDirectory == true, sourceValues.isSymbolicLink != true
        else { throw LauncherError.unsafeFile(source.lastPathComponent) }
        // Prevent a caller from importing our own staging/payload tree recursively.
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard !rootPath.hasPrefix(sourcePath), !sourcePath.hasPrefix(rootPath)
        else { throw LauncherError.unsafeFile("导入来源与应用存储目录重叠") }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var stack: [(URL, URL, String)] = [(source, destination, "")]
        var entries = 0
        var result = CopyResult()
        var bytesSinceCheckpoint = 0
        while let (input, output, relative) = stack.popLast() {
            try Task.checkCancellation()
            let children = try fm.contentsOfDirectory(at: input, includingPropertiesForKeys: Array(keys))
            var names = Set<String>()
            for child in children {
                try Task.checkCancellation()
                entries += 1
                if entries % 128 == 0 { try await checkpoint() }
                guard entries <= maxEntries else { throw LauncherError.limitExceeded }
                let name = child.lastPathComponent
                guard names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                      !name.contains("\\"), !name.contains(":"),
                      !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                else { throw LauncherError.unsafeFile(name) }
                let values = try child.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true else { throw LauncherError.unsafeFile(name) }
                let target = output.appendingPathComponent(name)
                let path = relative.isEmpty ? name : "\(relative)/\(name)"
                if values.isDirectory == true {
                    try fm.createDirectory(at: target, withIntermediateDirectories: false)
                    stack.append((child, target, path))
                } else if values.isRegularFile == true {
                    let hashKey = path.lowercased()
                    let needsHash = hashKey == "slaythespire2.pck" || hashKey == "\(Self.dataDir)/sts2.dll"
                    var digest: SHA256? = needsHash ? SHA256() : nil
                    // Stream files: neither a whole PCK nor a growing provider file fits in RAM.
                    let reader = try FileHandle(forReadingFrom: child)
                    defer { try? reader.close() }
                    guard fm.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                    let writer = try FileHandle(forWritingTo: target)
                    defer { try? writer.close() }
                    while true {
                        try Task.checkCancellation()
                        guard let chunk = try reader.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
                        result.bytes += Int64(chunk.count)
                        guard result.bytes <= maxBytes else { throw LauncherError.limitExceeded }
                        try writer.write(contentsOf: chunk)
                        // Hash exactly the chunks written, without rereading multi-GB payloads.
                        digest?.update(data: chunk)
                        bytesSinceCheckpoint += chunk.count
                        if bytesSinceCheckpoint >= 8 * 1024 * 1024 {
                            bytesSinceCheckpoint = 0
                            try await checkpoint()
                        }
                    }
                    if let digest {
                        result.hashes[hashKey] = digest.finalize().map { String(format: "%02x", $0) }.joined()
                    }
                } else { throw LauncherError.unsafeFile(name) }
            }
        }
        return result
    }
}

private struct ReleaseInfo: Decodable { let version: String }
