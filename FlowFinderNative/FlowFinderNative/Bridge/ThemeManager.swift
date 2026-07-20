import Foundation
import AppKit
import Combine

/// 外观模式枚举
public enum AppearanceMode: Int, CaseIterable {
    case system = 0  // 跟随系统
    case light = 1   // 浅色
    case dark = 2    // 深色

    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    public var iconName: String {
        switch self {
        case .system: return "circle.lefthalf.filled.righthalf.stripes.horizontal"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

/// 主题管理器：管理应用外观模式（浅色/深色/跟随系统）
public final class ThemeManager: ObservableObject {

    public static let shared = ThemeManager()

    /// 设置键名
    private let settingsKey = "appearance_mode"

    @Published public private(set) var currentMode: AppearanceMode = .system

    /// 主题变更回调
    public var onModeChanged: ((AppearanceMode) -> Void)?

    private init() {
        loadSavedMode()
    }

    // MARK: - Public API

    /// 应用指定外观模式
    /// - Parameter mode: 外观模式
    public func applyMode(_ mode: AppearanceMode) {
        currentMode = mode
        saveMode(mode)

        switch mode {
        case .system:
            NSApp.appearance = nil  // 跟随系统
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }

        // 通知所有窗口刷新
        for window in NSApp.windows {
            window.appearance = NSApp.appearance
        }

        onModeChanged?(mode)
    }

    /// 开始监听系统主题变更（仅当 currentMode == .system 时生效）
    public func startObservingSystemChanges() {
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(systemAppearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    /// 停止监听
    public func stopObservingSystemChanges() {
        DistributedNotificationCenter.default.removeObserver(self)
    }

    /// 获取当前系统外观（用于 .system 模式判断）
    public var systemIsDark: Bool {
        guard let appearance = NSAppearance.currentAppearance else { return false }
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: - Private

    @objc private func systemAppearanceChanged() {
        // 仅在跟随系统模式下触发刷新
        if currentMode == .system {
            NSApp.appearance = nil
            for window in NSApp.windows {
                window.appearance = nil
            }
            onModeChanged?(.system)
        }
    }

    private func loadSavedMode() {
        // 优先从 CoreBridge 读取，回退到 UserDefaults
        let rustValue = CoreBridge.shared.getSetting(key: settingsKey)

        if !rustValue.isEmpty, let intValue = Int(rustValue), let mode = AppearanceMode(rawValue: intValue) {
            currentMode = mode
        } else if let savedValue = UserDefaults.standard.object(forKey: settingsKey) as? Int,
                  let mode = AppearanceMode(rawValue: savedValue) {
            currentMode = mode
        } else {
            currentMode = .system
        }
    }

    private func saveMode(_ mode: AppearanceMode) {
        // 保存到两处：CoreBridge（Rust 端）和 UserDefaults（快速读取）
        UserDefaults.standard.set(mode.rawValue, forKey: settingsKey)

        do {
            try CoreBridge.shared.setSetting(key: settingsKey, value: String(mode.rawValue))
        } catch {
            print("ThemeManager: 保存主题到 Rust 失败: \(error.localizedDescription)")
        }
    }
}
