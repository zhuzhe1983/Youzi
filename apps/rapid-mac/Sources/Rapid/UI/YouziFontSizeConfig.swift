import AppKit
import Foundation
import Observation
import SwiftUI

/// App-wide font size scale configuration.
/// Offers 4 discrete font sizes: small (小), medium (中 - default), large (大), extraLarge (超大).
/// Supports global keyboard shortcut zooming (Ctrl+- / Ctrl++ / Cmd+- / Cmd++).
enum YouziFontSize: String, CaseIterable, Identifiable, Sendable {
    case small = "small"
    case medium = "medium"
    case large = "large"
    case extraLarge = "extraLarge"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        case .extraLarge: return "超大"
        }
    }

    func localizedDisplayName(isChinese: Bool) -> String {
        if isChinese { return displayName }
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    /// Scaling multiplier applied to custom UI typography.
    var scale: CGFloat {
        switch self {
        case .small: return 0.88
        case .medium: return 1.00
        case .large: return 1.16
        case .extraLarge: return 1.32
        }
    }

    /// Point adjustment added to base typography.
    var pointDelta: CGFloat {
        switch self {
        case .small: return -1.5
        case .medium: return 0
        case .large: return 2.0
        case .extraLarge: return 4.0
        }
    }

    /// Matching SwiftUI DynamicTypeSize for system text styles and ScaledMetric.
    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .small: return .small
        case .medium: return .large
        case .large: return .xxLarge
        case .extraLarge: return .accessibility1
        }
    }
}

@MainActor
@Observable
final class YouziFontSizeConfig: @unchecked Sendable {
    static let shared = YouziFontSizeConfig()
    nonisolated static let storageKey = "youzi.font_size.v1"

    nonisolated static var currentScale: CGFloat {
        if let raw = UserDefaults.standard.string(forKey: storageKey),
           let saved = YouziFontSize(rawValue: raw) {
            return saved.scale
        }
        return YouziFontSize.medium.scale
    }

    private let defaults: UserDefaults

    var size: YouziFontSize {
        didSet {
            defaults.set(size.rawValue, forKey: Self.storageKey)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.storageKey),
           let saved = YouziFontSize(rawValue: raw) {
            self.size = saved
        } else {
            self.size = .medium
        }
    }

    var scale: CGFloat { size.scale }
    var pointDelta: CGFloat { size.pointDelta }
    var dynamicTypeSize: DynamicTypeSize { size.dynamicTypeSize }

    func scaled(_ base: CGFloat) -> CGFloat {
        max(9, round(base * scale))
    }

    func font(_ base: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        Font.system(size: scaled(base), weight: weight, design: design)
    }

    /// Step down to smaller font size (Ctrl+-).
    func zoomOut() {
        switch size {
        case .extraLarge: size = .large
        case .large: size = .medium
        case .medium, .small: size = .small
        }
    }

    /// Step up to larger font size (Ctrl++ / Ctrl+=).
    func zoomIn() {
        switch size {
        case .small: size = .medium
        case .medium: size = .large
        case .large, .extraLarge: size = .extraLarge
        }
    }

    /// Reset to medium standard size (Ctrl+0).
    func reset() {
        size = .medium
    }
}
