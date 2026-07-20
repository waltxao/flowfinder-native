import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 应用保存的主题
        ThemeManager.shared.startObservingSystemChanges()
        ThemeManager.shared.applyMode(ThemeManager.shared.currentMode)

        // 设置菜单栏
        MainMenu.setupMainMenu()

        // 创建主窗口
        let controller = MainWindowController()
        controller.showWindow(nil)
        self.mainWindowController = controller
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
