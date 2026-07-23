# Task 11: 全局撤销/重做栈

## 目标

为 FlowFinder Native 实现全局撤销/重做栈，支持文件移动、复制、重命名、删除四类操作的撤销与重做。Edit 菜单的"撤销"/"重做"连接到 UndoManager，⌘Z/⌘⇧Z 快捷键生效。

## 验收标准（来自 checklist.md）

- [ ] 文件移动后 ⌘Z 撤销，文件回到原位
- [ ] 文件重命名后 ⌘Z 撤销，名称恢复
- [ ] 复制后 ⌘Z 撤销，复制的文件被删除
- [ ] 删除（移到废纸篓）后 ⌘Z 撤销，文件从废纸篓恢复
- [ ] ⌘⇧Z 重做被撤销的操作
- [ ] Edit 菜单"撤销"/"重做"标题随栈状态动态更新（如"撤销 移动"）

## 架构决策

### UndoManager 位置：MainWindowController（per-window）

在 `MainWindowController` 中添加 `private let undoManager = UndoManager()`。Cocoa 的 undo 响应链会自动将 `undo:`/`redo:` selector 路由到 window 的 undoManager。MainWindowController 持有 leftPaneViewModel/rightPaneViewModel，撤销时可直接调用对应 VM 的 `refresh()`。

### 删除策略：改用 FileManager.trashItem

**当前问题**：`PaneViewModel.deleteSelected()` (PaneState.swift:184) 调用 `CoreBridge.shared.parallelDelete`，底层是 `std::fs::remove_file`（永久删除），不可撤销。

**改为**：在 Swift 层使用 `FileManager.default.trashItem(at:resultingItemURL:)` 移到废纸篓。原因：
1. 菜单标签已是"移动到废纸篓"（MainMenu.swift:40），实现应与标签一致
2. 符合原生 macOS 行为（Finder 的删除就是移到废纸篓）
3. `trashItem` 返回废纸篓中的 URL，可用于撤销时恢复
4. 用户偏好原生 macOS 一致性（project_memory）

`trashItem` 是串行的，但对于删除操作（通常选中文件数不会极大）性能可接受。保留 `parallelDelete` FFI 供其他场景使用，但 `deleteSelected` 改用 trashItem。

### 撤销注册点

| 操作 | 注册位置 | 撤销动作 |
|------|---------|---------|
| 重命名 | `PaneViewModel.renameFile(_:to:)` (PaneState.swift:219) | 反向 rename：`renameFile(src: newPath, dst: oldPath)` |
| 移动（跨面板/拖拽/剪贴） | `MainWindowController` 各 move 调用点 | 反向 move：把 dst 移回 src |
| 复制（跨面板/拖拽/剪贴） | `MainWindowController` 各 copy 调用点 | 删除 dst 中复制的文件 |
| 删除 | `PaneViewModel.deleteSelected()` | 从废纸篓恢复：`FileManager.moveItem` 从 trash URL 移回原路径 |

## 实现细节

### 1. MainWindowController 添加 UndoManager

```swift
public class MainWindowController: NSWindowController {
    private let undoManager = UndoManager()
    // ...
    
    // 让 window 使用此 undoManager
    override var windowUndoManager: UndoManager? {
        undoManager
    }
}
```

在 `setupUI()` 中（window 创建后），无需额外设置——`windowUndoManager` 的 override 会让 NSWindow 使用它。

### 2. 菜单连接

修改 `MainMenu.swift:47-48`：
- 将 `Selector(("undo:"))` 改为 `#selector(MainWindowController.undo(_:))`
- 将 `Selector(("redo:"))` 改为 `#selector(MainWindowController.redo(_:))`
- 但 MainMenu.setupMainMenu() 是静态方法，不持有 controller 引用。保留 `Selector(("undo:"))` 字符串形式即可——Cocoa 响应链会自动找到 window 的 undoManager 并调用其 `undo()`/`redo()`。**无需修改 MainMenu.swift**，只要 MainWindowController override 了 `windowUndoManager`，响应链自动工作。

为支持菜单标题动态更新（"撤销 移动"），在 MainWindowController 中实现：
```swift
@objc func undo(_ sender: Any?) {
    undoManager.undo()
}
@objc func redo(_ sender: Any?) {
    undoManager.redo()
}
```
并通过 `undoManager.removeAllActions()` / `undoManager.setActionName(_:)` 管理标题。使用 `NotificationCenter` 或在 `undo`/`redo` 后刷新菜单标题。

**简化方案**：菜单标题动态更新是 nice-to-have，优先保证功能正确。如果动态标题实现复杂，先让菜单显示静态"撤销"/"重做"，功能正确即可。

### 3. 重命名撤销（PaneViewModel.renameFile）

```swift
func renameFile(_ oldPath: String, to newName: String) {
    let dir = (oldPath as NSString).deletingLastPathComponent
    let newPath = (dir as NSString).appendingPathComponent(newName)
    do {
        try CoreBridge.shared.renameFile(src: oldPath, dst: newPath)
        // 注册撤销
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.renameFile(newPath, to: (oldPath as NSString).lastPathComponent)
        }
        undoManager?.setActionName("重命名")
        loadDirectory()
    } catch {
        state.error = error.localizedDescription
    }
}
```

PaneViewModel 需要能访问 undoManager。两种方式：
- 方式 A：PaneViewModel 持有 weak undoManager 引用（由 MainWindowController 在初始化时注入）
- 方式 B：通过闭包回调让 MainWindowController 注册撤销

**推荐方式 A**：在 PaneViewModel 添加 `weak var undoManager: UndoManager?`，MainWindowController 在 `setupUI()` 中设置 `leftPaneViewModel.undoManager = undoManager` 和 `rightPaneViewModel.undoManager = undoManager`。

### 4. 移动撤销

移动的撤销是反向移动。对于批量移动（parallelMove），需要记录每个 src→dst 的映射。

在 `MainWindowController.performCrossPaneOperation(side:isMove:)` (line 762) 和 `menuPaste` (cut 模式, line 656) 和 `FileListView/FileGridView.performDragOperation` 中，移动成功后注册撤销：

```swift
// 记录 srcs 和 dstDir
let movedFiles = srcs.map { src -> (src: String, dst: String) in
    let name = (src as NSString).lastPathComponent
    return (src: src, dst: (dstDir as NSString).appendingPathComponent(name))
}
// 注册撤销：把每个 dst 移回 src
undoManager.registerUndo(withTarget: self) { ctrl in
    for (src, dst) in movedFiles {
        try? CoreBridge.shared.moveFile(src: dst, dst: src)
    }
    ctrl.refreshPane(.left)
    ctrl.refreshPane(.right)
}
undoManager.setActionName("移动 \(movedFiles.count) 个项目")
```

### 5. 复制撤销

复制的撤销是删除 dst 中的文件。同样记录 srcs 和 dstDir，撤销时删除 dst 文件：

```swift
let copiedFiles = srcs.map { src -> String in
    let name = (src as NSString).lastPathComponent
    return (dstDir as NSString).appendingPathComponent(name)
}
undoManager.registerUndo(withTarget: self) { ctrl in
    for dst in copiedFiles {
        try? CoreBridge.shared.deleteFile(path: dst)
    }
    ctrl.refreshPane(at: dstDir)
}
undoManager.setActionName("复制 \(copiedFiles.count) 个项目")
```

### 6. 删除撤销（改用 trashItem）

修改 `PaneViewModel.deleteSelected()` (PaneState.swift:184)：

```swift
func deleteSelected() {
    let selected = state.selectedFiles
    guard !selected.isEmpty else { return }
    
    var trashedItems: [(originalPath: String, trashURL: URL)] = []
    var failedCount = 0
    
    for entry in selected {
        let url = URL(fileURLWithPath: entry.path)
        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            if let trashURL = resultingURL as URL? {
                trashedItems.append((entry.path, trashURL))
            }
        } catch {
            failedCount += 1
        }
    }
    
    if !trashedItems.isEmpty {
        // 失效缓存
        let parentDir = (trashedItems[0].originalPath as NSString).deletingLastPathComponent
        try? CoreBridge.shared.invalidateCache(path: parentDir)
        
        // 注册撤销：从废纸篓恢复
        let items = trashedItems
        undoManager?.registerUndo(withTarget: self) { vm in
            for (originalPath, trashURL) in items {
                try? FileManager.default.moveItem(at: trashURL, to: URL(fileURLWithPath: originalPath))
            }
            vm.loadDirectory()
        }
        undoManager?.setActionName("删除 \(trashedItems.count) 个项目")
        
        state.selectedFiles.removeAll()
        loadDirectory()
    }
    
    if failedCount > 0 {
        state.error = "\(failedCount) 个项目删除失败"
    }
}
```

注意：`trashItem` 的 resultingURL 是文件在废纸篓中的实际路径（~/.Trash/ 下，可能带后缀如 "file (1).txt"）。恢复时 moveItem 回原路径即可。

### 7. 刷新辅助方法

在 MainWindowController 添加：
```swift
private func refreshPane(_ side: PaneSide) {
    let vm = side == .left ? leftPaneViewModel : rightPaneViewModel
    vm.refresh()
}
```

### 8. 撤销/重做后刷新视图

所有 undo 闭包执行后必须刷新受影响的 pane。由于 `PaneViewModel.state` 是 `@Published`，调用 `refresh()`（即 `loadDirectory()`）会自动触发 Combine 订阅更新 UI。

## 受影响文件

| 文件 | 改动 |
|------|------|
| `FlowFinderNative/UI/MainWindowController.swift` | 添加 undoManager、windowUndoManager override、undo/redo 方法、refreshPane 辅助、各操作注册撤销 |
| `FlowFinderNative/Model/PaneState.swift` | PaneViewModel 添加 weak undoManager 属性；renameFile 注册撤销；deleteSelected 改用 trashItem + 注册撤销 |
| `FlowFinderNative/UI/FileListView.swift` | performDragOperation 中的 move/copy 注册撤销（通过 viewModel 或通知） |
| `FlowFinderNative/UI/FileGridView.swift` | 同 FileListView |
| `FlowFinderNative/UI/MainMenu.swift` | 无需修改（Selector 字符串形式已可被响应链路由）。可选：动态标题更新 |

## 注意事项

1. **撤销闭包中的错误处理**：undo 闭包内的操作失败时，用 `try?` 静默忽略并刷新视图，不要向用户抛错（撤销应是 best-effort）。
2. **重做支持**：`UndoManager.registerUndo` 自动支持重做——当撤销闭包执行时，在其中再次 `registerUndo` 注册反向操作即可。但闭包内调用 `renameFile`/`moveFile` 等会再次注册撤销，形成重做链。为避免无限递归，undo 闭包内应直接调用 CoreBridge 而非经过会注册撤销的公开方法，或在公开方法中加参数控制是否注册撤销。
   - **推荐**：undo 闭包内直接调用 `CoreBridge.shared.xxx`，不调用会注册撤销的公开方法。这样重做由 UndoManager 自动管理。
3. **批量操作部分失败**：移动/复制时若部分失败，只对成功的部分注册撤销。
4. **trashItem 线程安全**：`trashItem` 必须在主线程调用（Foundation 限制）。当前 `deleteSelected` 在主线程调用，OK。
5. **菜单标题动态更新**：可选实现。若实现，监听 undoManager 栈变化更新菜单项 title。

## 验证步骤

1. 编译：`cargo check`（Rust 无改动，应 0 错误）
2. 编译：Xcode build（Swift 改动）
3. 手动测试：
   - 重命名文件 → ⌘Z → 名称恢复 → ⌘⇧Z → 名称再次改变
   - 拖拽移动文件到另一面板 → ⌘Z → 文件回到原面板 → ⌘⇧Z → 文件移回
   - 复制文件 → ⌘Z → 复制的文件被删除
   - 选中文件删除 → ⌘Z → 文件从废纸篓恢复
4. `cargo test` 应仍 88 passed（Rust 无改动）
