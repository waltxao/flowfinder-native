# FlowFinder 重构日志

> 完整记录 FlowFinder 从 Tauri + React + Rust 架构重构为 Swift & AppKit + Rust Core 架构的历史过程。

---

## 1. 重构背景

### 1.1 原版架构

FlowFinder 原版采用 Tauri 2.0 + React 19 + Rust 技术栈：

```
Tauri 2.0 (Rust 后端) ← IPC → React 19 (TypeScript) ← WebView → 用户
```

### 1.2 重构动机

| 维度 | 原版（Tauri + React）问题 | 新版（Swift & AppKit）方案 |
|------|--------------------------|---------------------------|
| UI 原生度 | WebView 渲染，无法完全匹配 macOS 原生外观 | 纯 NSVisualEffectView 玻璃态，完全原生 |
| 启动速度 | 需加载 WebView 运行时（2-3s） | 原生二进制，即时启动（0.5s） |
| 内存占用 | WebView + React 运行时开销（50-100 MB） | 仅 Swift + Rust Core（20-30 MB） |
| 系统集成 | 通过 Tauri IPC 间接调用系统 API | 直接调用 AppKit / Foundation API |
| 拖拽体验 | HTML5 拖拽，与系统行为不一致 | 原生 NSDraggingSource/Destination |
| QuickLook | 通过 Swift Bridge 中转 | 直接使用 QLPreviewPanel 单例 |
| 二进制大小 | 80-100 MB（含 WebView） | 15-20 MB |

### 1.3 决策

保留高性能 Rust Core 引擎，仅重写 UI 层为 Swift & AppKit，通过 FFI（C ABI）连接两者。

---

## 2. 架构对比

### 2.1 原版架构

```
┌─────────────────────────────────┐
│  React 19 + TypeScript 前端     │
│  - Tailwind CSS 样式            │
│  - Zustand 状态管理             │
│  - react-virtual 虚拟列表        │
│  - HTML5 拖拽                   │
└─────────────────────────────────┘
              ↕ Tauri IPC
┌─────────────────────────────────┐
│  Tauri 2.0 (Rust) 后端           │
│  - Tauri Commands               │
│  - Tauri Menu API               │
│  - WKWebView 透明背景            │
└─────────────────────────────────┘
              ↕ Swift FFI
┌─────────────────────────────────┐
│  Swift 静态库 (FFI Bridge)       │
│  - QLThumbnailGenerator          │
│  - FSEvents                     │
│  - Spotlight NSMetadataQuery    │
│  - QuickLook QLPreviewPanel     │
└─────────────────────────────────┘
              ↕ Rust FFI
┌─────────────────────────────────┐
│  Rust Core Engine                │
│  - BLAKE3 / SQLite / rayon       │
│  - getattrlistbulk / clonefile    │
└─────────────────────────────────┘
```

### 2.2 新版架构

```
┌─────────────────────────────────┐
│  Swift & AppKit UI Layer         │
│  - NSTableView / NSCollectionView│
│  - NSSplitView 双栏布局          │
│  - NSVisualEffectView 毛玻璃     │
│  - QLPreviewPanel Quick Look     │
│  - Spotlight NSMetadataQuery     │
│  - NSDraggingSource/Destination  │
└─────────────────────────────────┘
              ↕ FFI (C ABI)
┌─────────────────────────────────┐
│  Rust Core Engine (cdylib)       │
│  - BLAKE3 / SQLite / rayon       │
│  - getattrlistbulk / clonefile    │
│  - dir_cache / task_scheduler     │
└─────────────────────────────────┘
```

### 2.3 保留的 Rust Core 模块

以下 Rust Core 模块在重构中完整保留，仅通过 FFI 重新暴露接口：

- `bulk_read`：getattrlistbulk 批量目录读取
- `scanner`：文件扫描与元数据
- `dedup_engine`：三阶段 BLAKE3 重复检测
- `cow_copy`：APFS copy-on-write 克隆复制
- `dir_cache`：LRU + TTL 目录缓存
- `task_scheduler`：统一任务调度
- `search_engine`：正则 / 通配符搜索
- `sqlite_cache`：标签 / 缩略图持久化
- `path_guard`：路径穿越防护
- `volumes`：卷管理
- `batch_ops`：批量操作
- `parallel_ops`：并行操作
- `file_ops`：文件操作
- `fsevents`：FSEvents 文件系统监控
- `thumbnails`：缩略图元数据
- `settings`：设置持久化

### 2.4 重写的模块

| 模块 | 原版技术 | 新版技术 |
|------|---------|---------|
| UI 层 | React 19 + TypeScript | Swift 5.9 + AppKit |
| 样式 | Tailwind CSS 4.0 | NSVisualEffectView + 原生 |
| 状态管理 | Zustand 5.0 | Combine + ObservableObject |
| 虚拟列表 | react-virtual | NSTableView（原生虚拟化） |
| 缩略图 | Rust FFI | QLThumbnailGenerator（Swift 原生） |
| QuickLook | Swift Bridge 中转 | QLPreviewPanel 单例直调 |
| 搜索 | Tauri Commands | SearchBridge + SpotlightBridge |
| 拖拽 | HTML5 Drag API | NSDraggingSource/Destination |
| 毛玻璃 | CSS backdrop-filter | NSVisualEffectView |
| 右键菜单 | Tauri Menu API | NSMenu |
| 窗口管理 | Tauri Window | NSWindowController |

---

## 3. 重构时间线

### Phase 0：POC 验证（2026-07-17）

**目标**：验证 Swift & AppKit + Rust Core FFI 架构可行性

**完成内容**：
- 搭建 FFI 桥接层：`ff_list_dir`、`ff_last_error`、`ff_free_string`
- 实现目录列表：使用 `getattrlistbulk(2)` 批量读取，验证 10-30x 性能提升
- 搭建基础 UI 框架：`MainWindowController`、`ContentView`、`FileListView`、`SidebarView`
- 定义数据模型：`FileEntry`、`FileEntryViewModel`
- 配置构建系统：`Makefile`、`Package.swift`、`build-rust.sh`

**验证结果**：POC 成功，FFI 桥接稳定，性能提升显著，决定全面重构。

### Phase 1：MVP 核心功能（2026-07-18 ~ 2026-07-19）

**目标**：实现可日常使用的最小可用版本

**子项目**：
- **#1 文件操作**：复制 / 移动 / 删除 / 重命名，APFS CoW 复制，废纸篓支持
- **#3 搜索过滤**：文件名正则搜索，大小 / 日期 / 类型过滤，Spotlight 集成
- **#4 Quick Look**：QLPreviewPanel 空格键预览，多文件类型支持

### Phase 2：增强功能（2026-07-19 ~ 2026-07-20）

**目标**：实现高级文件操作和系统级集成

**子项目**：
- **#2 重复文件检测**：三阶段 BLAKE3 哈希，实时进度流，安全删除，SQLite 缓存
- **#5 目录缓存与 FSEvents**：LRU + TTL 缓存，FSEvents 自动刷新
- **#6 批量重命名**：模式替换、序号添加、大小写转换

### Phase 3：完善功能（2026-07-20）

**目标**：用户体验优化和系统级功能

**子项目**：
- **#7 缩略图生成**：QLThumbnailGenerator + SQLite 缓存，P0/P1 双队列
- **#8 设置配置**：通用设置、外观主题、AI 模型配置
- **#9 任务调度器**：统一任务队列，暂停 / 恢复 / 取消

### Phase 4：收尾与玻璃态重构（2026-07-20）

**目标**：系统级功能和视觉重构

**子项目**：
- **#10 卷管理**：磁盘列表、健康检查、空间监控
- **玻璃态双栏重构**：MainWindowController 双 DetailsBar + vibrancy 背景，PaneToolbar 双行布局
- **SidebarView 玻璃态**：动态刷新，折叠区段

### Phase 5：跨面板操作与发布（2026-07-21）

**目标**：修复遗留问题，实现跨面板文件操作，发布 0.6.0-alpha

**完成内容**：
- **修复右键菜单失效**：FileListView 发送通知但 MainWindowController 未订阅，新增 6 个通知订阅
- **面板激活接线**：添加 NSClickGestureRecognizer，点击面板即激活
- **跨面板复制 / 移动**：⌘⇧C / ⌘⇧X，冲突自动追加「副本 N」
- **在对侧面板打开**：文件夹右键菜单直接在对侧面板打开
- **FileGridView 右键菜单同步**：与 FileListView 一致的完整右键菜单
- **菜单栏快捷键**：⌘⇧C、⌘⇧X 等完整快捷键支持
- **Release 构建打包**：FlowFinderNative_v3.zip / .dmg
- **0.6.0-alpha 发布**

---

## 4. 子项目完成状态

| # | 子项目 | 优先级 | 状态 | 完成时间 |
|---|--------|--------|------|---------|
| 0 | POC: 基础框架 | — | ✅ | 2026-07-17 |
| 1 | 文件操作 (Copy/Move/Delete) | P0 | ✅ | 2026-07-18 |
| 2 | 重复文件检测 | P0 | ✅ | 2026-07-19 |
| 3 | 文件搜索与过滤 | P0 | ✅ | 2026-07-18 |
| 4 | 文件预览 (QuickLook) | P0 | ✅ | 2026-07-19 |
| 5 | 目录缓存与 FSEvents | P1 | ✅ | 2026-07-19 |
| 6 | 批量重命名与整理 | P1 | ✅ | 2026-07-20 |
| 7 | 缩略图生成 | P1 | ✅ | 2026-07-20 |
| 8 | 设置与配置 | P2 | ✅ | 2026-07-20 |
| 9 | 任务调度器 | P2 | ✅ | 2026-07-20 |
| 10 | 卷管理与健康检查 | P2 | ✅ | 2026-07-20 |

---

## 5. 关键技术决策

### 5.1 为什么选择 Swift & AppKit 而非 SwiftUI？

- **成熟度**：AppKit 历经 20+ 年发展，API 稳定，文档完善
- **控制力**：AppKit 提供更精细的 UI 控制，适合文件管理器这类重度交互应用
- **NSVisualEffectView**：AppKit 的毛玻璃材质 API 比 SwiftUI 更成熟
- **NSTableView**：原生虚拟化列表，性能优于 SwiftUI List
- **兼容性**：支持 macOS 13.0+，SwiftUI 部分 API 需要 14.0+

### 5.2 为什么保留 Rust Core？

- **性能**：BLAKE3、rayon 并行、getattrlistbulk 等系统级操作 Rust 表现最优
- **复用性**：Rust Core 可跨 UI 框架复用（已用于 Tauri 和 Swift 两个版本）
- **内存安全**：Rust 的所有权模型避免内存泄漏和空指针
- **FFI 友好**：Rust 的 C ABI 导出稳定，Swift 调用方便

### 5.3 FFI 设计原则

- **C ABI 标准**：所有导出函数使用 `extern "C"`，参数类型为 C 兼容类型
- **所有权明确**：Rust 分配的内存由 Rust 释放（`ff_free_string`），Swift 分配的由 Swift 管理
- **错误传递**：返回值为 `c_int`（0 表示成功，非 0 表示错误码），错误详情通过 `ff_last_error` 获取
- **回调模式**：长时间操作使用回调函数传递进度，避免阻塞主线程

---

## 6. 数据流架构

### 6.1 文件浏览数据流

```
用户操作（点击目录）
    ↓
PaneViewModel.setCurrentPath(path)
    ↓
CoreBridge.shared.listDirectory(path)  ← Swift 桥接
    ↓
ff_list_dir(path)  ← FFI 调用
    ↓
Rust: bulk_read.getattrlistbulk()  ← 系统调用
    ↓
Rust: scanner.build_entries()  ← 构建文件列表
    ↓
返回 FFEntryRef[]  ← FFI 返回
    ↓
Swift: FileEntry[]  ← 数据映射
    ↓
PaneViewModel.files = [...]  ← Combine 发布
    ↓
FileListView / FileGridView 自动刷新  ← UI 更新
```

### 6.2 通知路由架构

跨组件通信使用 NotificationCenter 路由模式：

```
FileListView 右键菜单点击
    ↓
NotificationCenter.post(name: .fileListDidCopy, userInfo: ["side": "left"])
    ↓
MainWindowController.setupNotifications() 订阅
    ↓
handleFileListCopy(userInfo) 根据 side 路由到对应 PaneViewModel
    ↓
leftPaneViewModel.copySelected() 执行操作
```

### 6.3 跨面板操作流程

```
用户选择「复制到另一面板」
    ↓
FileListView.post(.fileListDidCopyToOther, ["side": "left"])
    ↓
MainWindowController.handleFileListCopyToOther(side: "left")
    ↓
performCrossPaneOperation(side: "left", isMove: false)
    ↓
源面板: leftPaneViewModel.selectedFiles
目标路径: rightPaneViewModel.currentPath
    ↓
冲突检测: 目标路径已存在 → 追加「副本 N」
    ↓
CoreBridge.shared.copyFile(src:dst:)  ← FFI
    ↓
rightPaneViewModel.refresh()  ← 刷新目标面板
```

---

## 7. 版本对应

| 原版版本 | 新版版本 | 说明 |
|---------|---------|------|
| 0.5.5 | — | 原版最终版本（已搁置） |
| — | 0.6.0-alpha | 新版首个 Release |

原版仓库（FlowFinder-T）仍可访问和下载，但不再接受功能更新。

---

## 8. 仓库变更记录

| 日期 | 操作 | 说明 |
|------|------|------|
| 2026-07-21 | `waltxao/FlowFinder` → `waltxao/FlowFinder-T` | 原版仓库重命名，标记为搁置 |
| 2026-07-21 | `waltxao/flowfinder-native` → `waltxao/FlowFinder` | 新版仓库继承原名，成为主仓库 |
| 2026-07-21 | 原版添加搁置公告横幅 + MIGRATION.md | 引导用户迁移到新版 |
| 2026-07-21 | 新版 README 中文重写 | 完整文档（介绍、功能、安装、开发、FAQ） |
| 2026-07-21 | 新版 0.6.0-alpha Release 发布 | 首个原生版本公开发布 |

---

## 9. 后续计划

### 0.6.x 系列目标

- [ ] Intel Mac 通用二进制支持
- [ ] 全局撤销 / 重做栈（支持多步操作回退）
- [ ] 批量重命名 UI 完善
- [ ] 文件分组显示
- [ ] 更完整的标签编辑 UI
- [ ] 性能优化（大目录 10 万+ 文件）

### 1.0 正式版目标

- [ ] 全面测试覆盖（单元 + 集成 + UI 自动化）
- [ ] 完整开发者文档
- [ ] 代码签名与公证
- [ ] 多语言支持（英文）
- [ ] 自动更新机制

---

## 10. 相关文档

| 文档 | 路径 | 说明 |
|------|------|------|
| 迁移计划 | [MIGRATION_PLAN.md](MIGRATION_PLAN.md) | 详细子项目迁移计划 |
| 验证清单 | [VERIFICATION.md](VERIFICATION.md) | POC 验证结果 |
| 变更日志 | [../CHANGELOG.md](../CHANGELOG.md) | 版本变更记录 |
| 原版迁移说明 | [FlowFinder-T/MIGRATION.md](https://github.com/waltxao/FlowFinder-T/blob/main/MIGRATION.md) | 原版迁移引导 |

---

*本文档记录了 FlowFinder 从 Tauri + React 到 Swift & AppKit 的完整重构历程。如有疑问，请提交 [Issue](https://github.com/waltxao/FlowFinder/issues)。*
