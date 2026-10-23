import Foundation

public struct InstalledPayload: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let version: String
    public let dllSHA256: String
    public let pckSHA256: String
    public let installedAt: Date
    public let byteCount: Int64
}

public struct LaunchProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let payloadID: UUID
    public let name: String
}

public struct LibraryState: Codable, Equatable, Sendable {
    public var schema: Int = 1
    public var payloads: [InstalledPayload] = []
    public var profiles: [LaunchProfile] = []
    public var selectedProfileID: UUID?
    public init() {}
    public var selectedProfile: LaunchProfile? {
        profiles.first { $0.id == selectedProfileID }
    }
}

public enum LauncherError: Error, LocalizedError {
    case invalidPayload(String)
    case unsafeFile(String)
    case limitExceeded
    case damagedIndex
    case missingProfile
    case runtimeUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidPayload(let reason): return "游戏目录无效：\(reason)"
        case .unsafeFile(let path): return "拒绝不安全的目录条目：\(path)"
        case .limitExceeded: return "目录超出导入限制（16 GiB 或 100,000 个条目）。"
        case .damagedIndex: return "版本索引损坏或格式不受支持。原有文件已保留，请先备份再排查。"
        case .missingProfile: return "所选配置或游戏文件不存在，请重新导入。"
        case .runtimeUnavailable:
            return "此构建尚未集成 iOS 游戏运行时。导入 PC 文件不代表已完成 iOS 移植；目前无法启动游戏。"
        }
    }
}

/// No success-shaped fallback: a UI or an imported PC DLL is not an iOS engine.
public enum GameRuntime {
    public static func launch() throws { throw LauncherError.runtimeUnavailable }
}

/// Exact unsigned decimal identity; never round manifest IDs through a Double.
public struct SteamManifestID: Equatable, Sendable {
    public let value: UInt64
    public init?(_ text: String) {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = UInt64(text), value > 0 else { return nil }
        self.value = value
    }
}
