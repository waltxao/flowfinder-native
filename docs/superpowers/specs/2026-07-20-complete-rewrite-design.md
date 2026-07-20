# FlowFinder 完整重构设计规格

> **版本**：v1.0.0  
> **日期**：2026-07-20  
> **状态**：已批准  
> **平台**：macOS 独占  
> **前置文档**：`2026-07-18-beta-ui-completion-design.md`（本文档替代其 Week 3/4 计划）

---

## 1. 背景与审查结论

### 1.1 审查结果

对 FlowFinder Native 项目进行了全面代码审查（Swift UI / Rust Core+FFI / 文档+git 历史），结论：

| 层级 | 审查前完成度 | 关键问题 |
|------|------------|---------|
| Rust Core（FFI 接口） | ~95% | sqlite/rayon 缺失；dedup_engine 用 md5 而非 blake3；ff_task_list/ff_volume_list 签名不一致 |
| Swift Bridge 层 | ~85% | searchCallback/dedupGroupCallback 空实现；CoreBridge unsafe 指针问题；FSEvents 回调空壳 |
| Swift UI 主框架 | ~70% | MainWindowController 约束 bug；PaneToolbar 菜单不弹出；FileListView 缺列/缺多选 |
| Swift UI 功能集成 | ~30% | 搜索/重复扫描/QuickLook 三条核心路径均未打通；Sidebar 与设计严重不符 |

### 1.2 重构策略

用户选择**策略 B：一次性重写 UI 层**，同时**同步修复 Bridge 层和 Rust Core**。

### 1.3 已确认的 13 项决策

| # | 决策项 | 选择 |
|---|--------|------|
| 1 | 推进策略 | 一次性重写 UI 层 |
| 2 | 修复范围 | UI + Bridge + Rust Core 全部修复 |
| 3 | 哈希算法 | 迁移到 blake3 |
| 4 | Sidebar 标签云 | 本地标签（用户手动添加），不含 AI 打标 |
| 5 | QuickLook | 原生 QLPreviewPanel 单例 + QLPreviewPanelDataSource |
| 6 | 搜索 | Rust search_engine + Spotlight NSMetadataQuery 双模式 |
| 7 | 视图模式 | 列表（NSTableView）+ 网格（NSCollectionView）双模式切换 |
| 8 | 文件操作 | 拖拽 + 菜单 + 快捷键（⌘C/⌘X/⌘V/⌘⌫）全套 |
| 9 | 缩略图 | 原生 QLThumbnailGenerator |
| 10 | 菜单栏 | 完整标准菜单栏（File/Edit/View/Window/Help）+ 全套快捷键 |
| 11 | 深色模式 | 跟随系统 + 手动切换选项（浅色/深色/跟随系统） |
| 12 | SMB | 完整 SMB 管理（挂载 + 列表 + 卸载 + 自动重连） |
| 13 | 任务调度 | 底部固定进度条 + ⌘0 独立任务面板窗口 |

---

## 2. 目标架构

### 2.1 架构总览

```
┌──────────────────────────────────────────────────────────────┐
│                    Swift & AppKit UI 层                      │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │              AppDelegate + MainMenu                   │  │
│  │  (菜单栏 File/Edit/View/Window/Help + 快捷键路由)       │  │
│  └────────────────────────────────────────────────────────┘  │
│  ┌──────────┬───────────────────────────────────┬─────────┐ │
│  │          │  Pane 1 (Toolbar + FileList/Grid)  │         │ │
│  │ Sidebar  ├───────────────────────────────────┤ Details │ │
│  │          │  Pane 2 (Toolbar + FileList/Grid)  │  Bar    │ │
│  │ 收藏夹    ├───────────────────────────────────┤         │ │
│  │ 标签云    │  TaskProgressBar (当前任务)         │         │ │
│  │ 存储设备  │                                   │         │ │
│  └──────────┴───────────────────────────────────┴─────────┘ │
│  ┌─────────────────┐  ┌──────────────┐  ┌──────────────┐   │
│  │ QuickLook       │  │ SearchPanel  │  │ TaskPanel    │   │
│  │ (QLPreviewPanel)│  │ (Spotlight+  │  │ (⌘0 独立窗口)│   │
│  │                 │  │  Rust 双模式) │  │              │   │
│  └─────────────────┘  └──────────────┘  └──────────────┘   │
│  ┌─────────────────┐  ┌──────────────┐  ┌──────────────┐   │
│  │ DuplicateScan   │  │ Settings     │  │ SMBManager   │   │
│  │ Window          │  │ Window      │  │ (挂载/卸载/  │   │
│  │                 │  │ (外观/快捷键)│  │  重连)       │   │
│  └─────────────────┘  └──────────────┘  └──────────────┘   │
└──────────────────────────┬───────────────────────────────────┘
                           │ FFI (C ABI)
┌──────────────────────────▼───────────────────────────────────┐
│                    Rust Core Library                         │
│  bulk_read │ cow_copy │ blake3(迁移) │ sqlite(新增) │ rayon  │
│  search_engine │ dedup_engine(blake3) │ dir_cache │ fsevents│
│  batch_ops │ thumbnails │ settings │ task_scheduler │ volumes│
│  smb_mount(新增) │ ffi 导出层                        │
└──────────────────────────────────────────────────────────────┘
```

### 2.2 组件拆分（14 个独立单元）

| # | 组件 | 职责 | 依赖 |
|---|------|------|------|
| 1 | `AppDelegate` + `MainMenu` | 应用生命周期、菜单栏、快捷键路由 | 所有 UI 组件 |
| 2 | `MainWindowController` | 主窗口布局（Sidebar + DualPane + DetailsBar + TaskBar） | 3,4,5,6,7 |
| 3 | `SidebarView` | 收藏夹 + 标签云 + 存储设备三区域 | Bridge(Volumes, Settings) |
| 4 | `PaneToolbar` | 每面板工具栏（导航/搜索/排序/分组/视图切换） | 5,6 |
| 5 | `FileListView` (列表) | NSTableView 4 列 + 多选 + 列头排序 + 右键菜单 + 拖拽 | 6, Bridge |
| 6 | `FileGridView` (网格) | NSCollectionView + 缩略图 + 拖拽 | Bridge(Thumbnails) |
| 7 | `DetailsBar` | 选中文件详情 + 创建日期 + 标签 | 5, Bridge(xattr) |
| 8 | `QuickLookPanel` | QLPreviewPanel 单例 + DataSource | 5 |
| 9 | `SearchPanel` | Rust 搜索 + Spotlight 双模式 + 结果面板 | Bridge(Search, Spotlight) |
| 10 | `DuplicateScanWindow` | 扫描 UI + 进度 + 分组结果 + 批量操作 | Bridge(Dedup) |
| 11 | `TaskProgressBar` + `TaskPanelWindow` | 底部进度条 + ⌘0 独立任务面板 | Bridge(TaskScheduler) |
| 12 | `SettingsWindow` | 外观切换 + 快捷键 + SMB 管理 | Bridge(Settings, SMB) |
| 13 | `SMBManager` | SMB 挂载/列表/卸载/重连 | Bridge(NetFS) |
| 14 | `ThumbnailManager` | QLThumbnailGenerator 缓存 + 异步加载 | QLThumbnailGenerator |

---

## 3. 数据流与状态管理

### 3.1 状态管理架构

采用**分层状态管理**，每个面板独立状态，通过 AppDelegate 作为全局协调者：

```
AppDelegate (全局协调者)
├── activePane: PaneSide  // 当前活跃面板
├── clipboard: [FileEntry]  // 跨面板复制剪切
├── appearance: AppearanceMode  // 浅色/深色/跟随系统
│
├── leftPaneViewModel: PaneViewModel  // 独立状态
│   ├── path / history / historyIndex
│   ├── files: [FileEntry]  // 已排序已过滤
│   ├── selectedFiles: [FileEntry]  // 有序，支持 Shift/Cmd
│   ├── viewMode: .list / .grid
│   ├── sortField / sortAscending
│   ├── searchQuery / searchMode (.local / .spotlight)
│   └── isLoading / error
│
├── rightPaneViewModel: PaneViewModel  // 与 leftPane 相同结构
│
├── sidebarState: SidebarState
│   ├── favorites: [FavoriteItem]  // 收藏夹（持久化到 UserDefaults）
│   ├── tags: [Tag]  // 本地标签（持久化到 SQLite）
│   └── volumes: [VolumeInfo]  // 存储设备（从 ff_volume_list 获取）
│
├── detailsState: DetailsState
│   ├── selectedFile: FileEntry?  // 来自活跃面板
│   ├── selectedCount: Int
│   └── tags: [Tag]  // 当前选中文件的标签
│
├── taskState: TaskState
│   ├── activeTasks: [TaskInfo]  // 进行中任务
│   ├── history: [TaskInfo]  // 历史任务
│   └── currentProgress: (Float, String)?  // (进度, 描述)
│
└── searchState: SearchState
    ├── mode: .localRust / .spotlight
    ├── query: String
    ├── results: [FileEntry]
    └── isSearching: Bool
```

### 3.2 核心数据流

#### 流 1：目录浏览

```
用户双击文件夹
  → PaneViewModel.navigate(to: path)
  → CoreBridge.listDirectory(path) [后台线程]
  → files = entries.filter(非隐藏) .sort()
  → @Published state 变更
  → FileListView.reloadData()
  → DetailsBar.setFile(nil)
```

#### 流 2：跨面板复制

```
面板1 选中文件 ⌘C
  → AppDelegate.clipboard = selectedFiles
  → clipboardMode = .copy

面板2 ⌘V
  → for file in clipboard:
      CoreBridge.copyFile(src: file.path, dst: panel2.path + file.name) [后台]
  → TaskProgressBar 显示进度
  → 完成后 panel2.refresh()
```

#### 流 3：搜索（双模式）

```
PaneToolbar 搜索框输入
  → 模式判断：
    - 本地搜索（默认）：CoreBridge.search(path, query) [Rust walkdir]
    - 全局搜索（用户切换）：SpotlightBridge.search(query) [NSMetadataQuery]
  → SearchBridge.searchCallback 解析 FFSearchResult C 结构体
  → results = [FileEntry]
  → SearchPanel 显示结果
  → 双击结果 → 活跃面板 navigate(to: file.path)
```

#### 流 4：重复扫描

```
DuplicateScanWindow 启动扫描
  → 选择扫描目录
  → DuplicateScanBridge.scanDuplicates(path)
  → dedupGroupCallback 解析 FFDuplicateGroup C 结构体
  → duplicateGroups = [DuplicateGroup]
  → DuplicateResultsView 显示分组
  → 用户选择保留项 → 批量删除其余
  → TaskProgressBar 显示进度
```

#### 流 5：QuickLook 预览

```
FileListView 空格键
  → QuickLookPanel.shared.show(files: selectedFiles)
  → QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
  → QLPreviewPanelDataSource 提供当前文件
  → 方向键切换预览文件（跨选择）
```

#### 流 6：文件操作

```
拖拽
  → FileListView/GridView 注册 NSDraggingDestination
  → performDragOperation → CoreBridge.copyFile/moveFile
  → TaskProgressBar 显示进度
  → 完成后目标面板 refresh()

菜单
  → 右键菜单"复制到..." → NSOpenPanel 选目录 → CoreBridge.copyFile

快捷键
  → ⌘C → clipboard = selectedFiles (copy)
  → ⌘X → clipboard = selectedFiles (cut)
  → ⌘V → paste to active panel
  → ⌘⌫ → move to trash
  → ⌘D → duplicate in place
  → Enter → inline rename
  → ⌘N → new folder
```

### 3.3 数据模型扩展

`FileEntry` 需扩展以支持完整功能：

```swift
public struct FileEntry: Identifiable, Equatable, Hashable {
    public let id: String  // 改为 path 作为唯一标识（不再用 UUID）
    public let path: String
    public let name: String
    public let fileExtension: String
    public let isDirectory: Bool
    public let isFile: Bool
    public let isSymlink: Bool
    public let isHidden: Bool  // 新增
    public let isSystemProtected: Bool  // 新增
    public let size: UInt64
    public let modificationDate: Date
    public let creationDate: Date  // 新增（从 FFEntryRef.created）

    // 标签（从 xattr 懒加载）
    public var tags: [Tag]?  // 新增
}
```

### 3.4 持久化策略

| 数据 | 存储方式 | 位置 |
|------|---------|------|
| 收藏夹 | UserDefaults | `~/Library/Preferences/FlowFinder.plist` |
| 本地标签 | SQLite（新增） | `~/Library/Application Support/FlowFinder/tags.db` |
| 应用设置 | Rust settings.rs（plist） | 已有 |
| 窗口布局 | NSSplitView autosaveName | 已有 |
| 缩略图缓存 | LRU 内存缓存 + 磁盘缓存 | `~/Library/Caches/FlowFinder/thumbnails/` |

### 3.5 线程模型

```
主线程：
  - 所有 UI 操作
  - @Published 状态变更（通过 .receive(on: DispatchQueue.main)）

FFI 串行队列（CoreBridge.ffiQueue）：
  - 所有 Rust 调用
  - 信号量保证串行

后台并发（DispatchQueue.global）：
  - 文件操作（复制/移动/删除）
  - 搜索执行
  - 重复扫描
  - 缩略图生成

Spotlight 回调队列：
  - NSMetadataQuery 结果通知
```

---

## 4. Rust Core + Bridge 修复清单

### 4.1 Rust Core 修复

| 模块 | 文件 | 改动 |
|------|------|------|
| blake3 迁移 | `dedup_engine.rs`, `scanner.rs` | md5 → blake3，`hash_file` 通过 FFI 暴露 |
| 新增 sqlite | `Cargo.toml`, `sqlite_cache.rs`(新建) | `rusqlite` 依赖，基于 mtime 的增量缓存表 |
| 新增 rayon | `Cargo.toml`, `parallel_ops.rs`(新建) | `rayon` 依赖，4 线程并行批量复制/移动/删除 |
| 修复签名 | `ffi/mod.rs` | `ff_task_list`/`ff_volume_list` 回调签名与 Swift 对齐 |
| 新增 SMB | `smb_mount.rs`(新建), `ffi/mod.rs` | `ff_smb_mount`/`ff_smb_unmount`/`ff_smb_list` FFI |
| 修复缩略图 | `thumbnails.rs` | 保留 FFI 接口但实际由 Swift QLThumbnailGenerator 接管 |

### 4.2 Bridge 层修复

| 模块 | 文件 | 改动 |
|------|------|------|
| 搜索回调 | `SearchBridge.swift` | 实现 `searchCallback` 解析 `FFSearchResult` C 结构体 |
| 重复扫描回调 | `SearchBridge.swift` | 实现 `dedupGroupCallback` 解析 `FFDuplicateGroup` C 结构体 |
| 任务调度 | `CoreBridge.swift` | `submitTask` 返回 task ID、`cancelTask` 类型改 u64、`listTasks` 修复 unsafe 指针 |
| 卷管理 | `CoreBridge.swift` | `listVolumes` 修复 unsafe 指针、`ff_volume_mount` 参数对齐 |
| FSEvents 回调 | `CoreBridge.swift` | `fseventsCallback` 实现变更通知、`stopFSEventsWatcher` 存储真实 handle |
| 新增 Spotlight | `SpotlightBridge.swift`(新建) | `NSMetadataQuery` 封装 |
| 新增 SMB | `SMBBridge.swift`(新建) | `NetFSMountURLSync` 封装 |
| 新增缩略图 | `ThumbnailBridge.swift`(新建) | `QLThumbnailGenerator` 封装 |
| 新增标签 | `TagBridge.swift`(新建) | xattr 读写 `com.flowfinder.tags` |

---

## 5. 实施计划

按依赖关系分为 6 个阶段，每个阶段可独立编译验证：

### Phase 1：Rust Core + Bridge 修复（3-4 天）

#### 5.1.1 Rust Core 修复

| 任务 | 文件 | 改动 |
|------|------|------|
| blake3 迁移 | `dedup_engine.rs`, `scanner.rs` | md5 → blake3，`hash_file` 通过 FFI 暴露 |
| 新增 sqlite | `Cargo.toml`, `sqlite_cache.rs`(新建) | `rusqlite` 依赖，基于 mtime 的增量缓存表 |
| 新增 rayon | `Cargo.toml`, `parallel_ops.rs`(新建) | `rayon` 依赖，4 线程并行批量复制/移动/删除 |
| 修复签名 | `ffi/mod.rs` | `ff_task_list`/`ff_volume_list` 回调签名与 Swift 对齐 |
| 新增 SMB | `smb_mount.rs`(新建), `ffi/mod.rs` | `ff_smb_mount`/`ff_smb_unmount`/`ff_smb_list` FFI |
| 修复缩略图 | `thumbnails.rs` | 保留 FFI 接口但实际由 Swift QLThumbnailGenerator 接管 |

#### 5.1.2 Bridge 层修复

| 任务 | 文件 | 改动 |
|------|------|------|
| 搜索回调 | `SearchBridge.swift` | 实现 `searchCallback` 解析 `FFSearchResult` C 结构体 |
| 重复扫描回调 | `SearchBridge.swift` | 实现 `dedupGroupCallback` 解析 `FFDuplicateGroup` C 结构体 |
| 任务调度 | `CoreBridge.swift` | `submitTask` 返回 task ID、`cancelTask` 类型改 u64、`listTasks` 修复 unsafe 指针 |
| 卷管理 | `CoreBridge.swift` | `listVolumes` 修复 unsafe 指针、`ff_volume_mount` 参数对齐 |
| FSEvents 回调 | `CoreBridge.swift` | `fseventsCallback` 实现变更通知、`stopFSEventsWatcher` 存储真实 handle |
| 新增 Spotlight | `SpotlightBridge.swift`(新建) | `NSMetadataQuery` 封装 |
| 新增 SMB | `SMBBridge.swift`(新建) | `NetFSMountURLSync` 封装 |
| 新增缩略图 | `ThumbnailBridge.swift`(新建) | `QLThumbnailGenerator` 封装 |
| 新增标签 | `TagBridge.swift`(新建) | xattr 读写 `com.flowfinder.tags` |

**验证目标**：Rust 编译通过、Swift 编译通过、`cargo test` 通过

### Phase 2：主窗口 + 双面板 + 文件列表（4-5 天）

#### 5.2.1 数据模型重建

| 任务 | 文件 | 改动 |
|------|------|------|
| FileEntry 扩展 | `FileEntry.swift` | id 改为 path、新增 fileExtension/isHidden/isSystemProtected/isSymlink/creationDate/tags |
| PaneState 重构 | `PaneState.swift` | 修复 sort/filter bug、selectedFiles 改有序数组、删除重复的 FileEntryViewModel |
| Tag 模型 | `Tag.swift`(新建) | id/name/color，SQLite 持久化 |

#### 5.2.2 主窗口布局

| 任务 | 文件 | 改动 |
|------|------|------|
| MainWindowController 重写 | `MainWindowController.swift` | 修复约束 bug、初始化 leftPaneView/rightPaneView、活跃面板切换、绑定 DetailsBar |
| PaneToolbar 重写 | `PaneToolbar.swift` | 面包屑可点击跳转、排序/分组用 NSPopUpButton、视图切换互斥选中 |
| FileListView 重写 | `FileListView.swift` | 4 列(名称/修改日期/类型/大小)、多选、列头排序、修复 viewModel 重复订阅、拖拽源+目标、右键菜单修复(用 NSOpenPanel) |

**验证目标**：应用启动、双面板显示文件、导航工作

### Phase 3：Sidebar + DetailsBar + 菜单栏（3-4 天）

| 任务 | 文件 | 改动 |
|------|------|------|
| SidebarView 重写 | `SidebarView.swift` | 三区域(收藏夹+标签云+存储设备)、移除主线程信号量、收藏夹 CRUD、标签 CRUD、卷列表 |
| DetailsBar 重写 | `DetailsBar.swift` | 修复 createdField、从 xattr 读取标签、修复折叠 Auto Layout 冲突、绑定选择事件 |
| 菜单栏 | `MainMenu.swift`(新建) | File/Edit/View/Window/Help 全套菜单、快捷键路由 |
| AppDelegate 扩展 | `AppDelegate.swift` | 集成菜单栏、外观管理、FSEvents 启动 |

**验证目标**：三区域 Sidebar、详情联动、快捷键工作

### Phase 4：文件操作 + QuickLook + 缩略图（3-4 天）

| 任务 | 文件 | 改动 |
|------|------|------|
| 拖拽实现 | `FileListView.swift`, `FileGridView.swift` | NSDraggingDestination、跨面板拖拽、拖拽视觉反馈 |
| 快捷键 | `MainWindowController.swift` | ⌘C/⌘X/⌘V/⌘⌫/⌘D/Enter/⌘N 全套 |
| QuickLook | `QuickLookPanel.swift`(重写) | QLPreviewPanel 单例 + QLPreviewPanelDataSource + 方向键切换 |
| 网格视图 | `FileGridView.swift`(新建) | NSCollectionView + 缩略图 + 拖拽 + 双击进入 |
| 缩略图管理 | `ThumbnailManager.swift`(新建) | QLThumbnailGenerator 异步生成 + LRU 缓存 + 磁盘缓存 |

**验证目标**：拖拽/快捷键/菜单操作、空格预览、网格视图

### Phase 5：搜索 + 重复扫描 + 任务调度（3-4 天）

| 任务 | 文件 | 改动 |
|------|------|------|
| 搜索面板 | `SearchPanel.swift`(重写) | 双模式切换(Rust/Spotlight)、结果列表、双击定位 |
| 重复扫描窗口 | `DuplicateScanWindow.swift`(重写) | 目录选择、进度、分组结果、批量删除/保留 |
| 任务进度条 | `TaskProgressBar.swift`(新建) | 底部固定、当前任务进度、可取消 |
| 任务面板 | `TaskPanelWindow.swift`(新建) | ⌘0 打开、所有任务列表、历史、取消 |

**验证目标**：双模式搜索、重复扫描、任务进度

### Phase 6：设置 + SMB + 深色模式 + 收尾（3-4 天）

| 任务 | 文件 | 改动 |
|------|------|------|
| 设置窗口 | `SettingsWindow.swift`(新建) | 外观切换(浅色/深色/跟随系统)、快捷键设置、高级选项 |
| SMB 管理 | `SMBManager.swift`(新建) | 挂载对话框、已挂载列表、卸载、自动重连 |
| 深色模式 | 全局 | 所有颜色用动态颜色、NSAppearance 切换、设置持久化 |
| 文档同步 | `MIGRATION_PLAN.md` 等 | 更新子项目状态、同步 spec 与实现 |
| 打包验证 | `.app` bundle | codesign、install_name_tool、完整功能验证 |

**验证目标**：设置面板、SMB 挂载、外观切换、打包

---

## 6. 验收标准

对照需求文档第六节：

| 指标 | 目标 | 验证方法 |
|------|------|---------|
| 冷启动 | < 1 秒 | Instruments Time Profiler |
| 50 万文件滚动 | ≥ 55fps | NSTableView Cell 重用 + Instruments |
| 内存稳定性 | 30 分钟增长 < 50MB | Instruments Allocations |
| P0 功能 | 全部实现且对等 | 功能验收清单 |
| P1 功能 | 完成度 ≥ 80% | 功能验收清单 |
| Rust 核心测试 | 单元测试通过 | `cargo test` |
| 深色模式 | 无需重启切换 | 系统切换测试 |
| HIG 合规 | 右键菜单/触控板/快捷键 | 人工验证 |

### 6.1 P0 功能验收清单

- [ ] 双栏文件浏览（NSSplitView + NSTableView 重用）
- [ ] 批量目录读取（Rust bulk_read.rs，FFI 调用）
- [ ] 文件复制/移动（Rust cow_copy.rs，FFI 调用）
- [ ] 文件删除（废纸篓）（NSFileManager trashItem）
- [ ] Quick Look 预览（QLPreviewPanel 原生）
- [ ] 文件图标/缩略图（NSWorkspace.icon + QLThumbnailGenerator）
- [ ] 深色/浅色模式（AppKit 原生 NSAppearance 自动适配 + 手动切换）

### 6.2 P1 功能验收清单

- [ ] Spotlight 搜索（NSMetadataQuery 原生查询）
- [ ] BLAKE3 去重（Rust，FFI 调用）
- [ ] SMB 网络挂载（NetFSMountURLSync 原生挂载 + 列表 + 卸载 + 重连）
- [ ] 本地标签云（xattr 读写，不含 AI 打标）

---

## 7. 风险与缓解

| 风险 | 严重性 | 缓解策略 |
|------|--------|---------|
| Swift + Rust FFI 调试困难 | 中 | Phase 1 先修复并验证所有 FFI 签名一致性 |
| NSTableView 50 万文件性能 | 中 | Cell 重用机制 + SQLite 增量缓存 + 分页加载 |
| QLThumbnailGenerator 异步回调生命周期 | 中 | ThumbnailManager 统一管理，LRU 缓存 |
| SMB 自动重连复杂度 | 中 | 先实现手动挂载/卸载，重连作为增强 |
| 一次性重写工作量 | 高 | 分 6 个阶段，每阶段独立编译验证 |

---

## 8. 总工期

| 阶段 | 天数 | 累计 |
|------|------|------|
| Phase 1 | 3-4 | 4 |
| Phase 2 | 4-5 | 9 |
| Phase 3 | 3-4 | 13 |
| Phase 4 | 3-4 | 17 |
| Phase 5 | 3-4 | 21 |
| Phase 6 | 3-4 | 25 |

**总计约 19-25 个工作日。**
