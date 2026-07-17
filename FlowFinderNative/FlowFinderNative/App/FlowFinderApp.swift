import SwiftUI

@main
struct FlowFinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 使用 EmptyView 进行手动 NSWindow 管理
        Settings {
            EmptyView()
        }
    }
}
