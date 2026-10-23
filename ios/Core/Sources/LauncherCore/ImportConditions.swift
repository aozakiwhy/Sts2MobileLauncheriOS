import Foundation

/// Applies to payload import only, never to a game's render loop or FPS.
public struct ImportConditions: Sendable {
    public enum Heat: Equatable, Sendable { case normal, warm, hot, critical }
    public let heat: Heat
    public let lowPower: Bool

    public init(heat: Heat = .normal, lowPower: Bool = false) {
        self.heat = heat
        self.lowPower = lowPower
    }

    public var shouldStop: Bool { heat == .hot || heat == .critical }
    public var delayNanoseconds: UInt64 {
        if heat == .warm { return 50_000_000 }
        return lowPower ? 25_000_000 : 0
    }

    public static func system() -> ImportConditions {
        #if os(iOS)
        let heat: Heat
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: heat = .normal
        case .fair: heat = .warm
        case .serious: heat = .hot
        case .critical: heat = .critical
        @unknown default: heat = .hot
        }
        return ImportConditions(heat: heat, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        #else
        return ImportConditions()
        #endif
    }
}
