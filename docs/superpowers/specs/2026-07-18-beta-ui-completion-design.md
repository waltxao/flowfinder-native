# FlowFinder Beta UI 补全设计规格

> **版本**：v0.5.0-beta  
> **日期**：2026-07-18  
> **状态**：待审核  
> **平台**：macOS 独占

---

## 1. 总览

### 1.1 目标

在 4 周内打通三条核心用户路径的完整链路，达到可 beta 状态：

1. **文件浏览/管理**：打开目录、查看文件列表、复制/移动/删除/重命名、创建文件夹、空格预览
2. **搜索**：输入关键词、查看结果、双击定位、右键操作
3. **重复文件扫描**：选择目录、扫描重复项、查看分组结果、批量删除/保留

### 1.2 原则

- 沿用原设计文档中的 FFI 接口和数据结构，不重新发明轮子
- Swift UI 优先使用 AppKit 原生组件，保证 macOS 原生体验
- 非核心功能（缩略图引擎、任务调度中心、网络韧性）延后至 beta 之后
- 保持与原项目设计决策的一致性，仅在架构适配层面调整

### 1.3 当前状态

| 模块 | 现状 |
|------|------|
| Rust Core | 已有完整文件操作、搜索、重复扫描、任务调度、卷管理实现 |
| FFI 层 | 已暴露 `ff_list_dir`、`ff_copy_file`、`ff_move_file`、`ff_delete_file`、`ff_search`、`ff_scan_duplicates` 等接口 |
| Swift CoreBridge | 已有同步/异步 API 封装 |
| Swift UI | 有完整视图骨架，但大量方法体为空或未接入 |

---

## 2. 第一节：文件浏览/管理路径

### 2.1 现状

- ✅ CoreBridge 已实现 `listDirectory`、`copyFile`、`moveFile`、`deleteFile`、`deleteDirectory`、`createDirectory`、`renameFile` 的同步/异步 API
- ✅ FileListView 已绑定复制/移动/删除/重命名/新建文件夹操作
- ❌ **SidebarView 为空骨架**，无目录树导航
- ❌ **面包屑导航缺失**，用户无法感知当前路径层级
- ❌ **QuickLookPreviewView 为空骨架**，空格预览未接入

### 2.2 设计决策

#### A. 目录树导航

- 复用 CoreBridge.listDirectory 递归构建目录树
- 使用 `NSOutlineView` 实现侧边栏，支持展开/折叠
- 点击目录项 → 调用 `viewModel.navigateToEntry` → 加载该目录

#### B. 面包屑导航

- 在 ContentView 顶部添加 `NSTextField` + 按钮组，显示当前路径的各层级
- 点击任意层级 → 导航到该目录

#### C. 空格预览

- 复用 SearchBridge 中的 QuickLookBridge（已存在）
- FileListView 选中文件按空格 → 调用 `QuickLookBridge.shared.show()`
- 与原设计文档的 Quick Look 方案一致

### 2.3 需要修改的文件

| 文件 | 改动 |
|------|------|
| `SidebarView.swift` | 实现 NSOutlineView 数据源和代理，调用 CoreBridge.listDirectory |
| `ContentView.swift` | 添加面包屑导航栏 |
| `QuickLookPreviewView.swift` | 删除空骨架，改为直接调用 QuickLookBridge |
| `MainWindowController.swift` | 集成 SearchView 和 DuplicateScanView 的显示逻辑 |

---

## 3. 第二节：搜索路径

### 3.1 现状

- ✅ SearchBridge 已实现 `search` 和 `searchWithFilters`，封装了 FFI 回调
- ✅ SearchView 有 SearchBarView（搜索框）和 SearchResultsView（结果表格）UI 骨架
- ❌ **SearchBarView.onSearch 未连接到 SearchBridge**
- ❌ **SearchBridge.searchCallback 为空**，未解析 FFSearchResult C 结构体
- ❌ **SearchResultsView 数据未填充**

### 3.2 设计决策

#### A. 搜索触发链路

1. 用户在 SearchBarView 输入关键词 → `searchFieldChanged()` 触发 `onSearch`
2. MainWindowController 接收到 onSearch → 调用 `SearchBridge.shared.search()`
3. SearchBridge 通过 FFI 调用 Rust `ff_search`
4. Rust 通过回调逐条返回 FFSearchResult
5. SearchBridge 解析回调 → 调用 `resultHandler` → 更新 SearchResultsView

#### B. 回调解析

- 在 SearchBridge 中实现 `searchCallback`，解析 Rust 返回的 C 结构体
- 结构体字段：path, name, size, modified, isDir
- 通过 `resultHandler` 在 main queue 更新 UI

#### C. 搜索结果操作

- 双击结果 → 在文件列表中定位到该文件（调用 CoreBridge.listDirectory + 高亮）
- 右键菜单 → 打开所在文件夹/删除文件

### 3.3 需要修改的文件

| 文件 | 改动 |
|------|------|
| `SearchBridge.swift` | 实现 searchCallback 和 searchWithFiltersCallback，解析 FFSearchResult |
| `SearchView.swift` | 将 SearchBarView.onSearch 连接到 SearchBridge；SearchResultsView 绑定数据源 |
| `MainWindowController.swift` | 添加搜索面板的显示/隐藏逻辑 |

---

## 4. 第三节：重复扫描路径

### 4.1 现状

- ✅ DuplicateScanBridge 已实现 `scanDuplicates` 和 `cancelScan`
- ✅ MainWindowController 有 `showDuplicateScan()` 方法，创建 DuplicateScanView
- ❌ **DuplicateScanView 为空骨架**，无进度显示、结果列表、操作按钮
- ❌ **dedupGroupCallback 未实现**，无法接收重复组数据
- ❌ **无保留/删除操作**，无法处理扫描结果

### 4.2 设计决策

#### A. 扫描流程 UI

1. 用户点击菜单"扫描重复文件" → MainWindowController 显示 DuplicateScanView 面板
2. 用户选择目录 → 调用 `DuplicateScanBridge.shared.scanDuplicates()`
3. 扫描过程中显示进度条和当前扫描文件
4. 扫描完成 → 显示重复组列表（每组展开显示所有重复文件）

#### B. 结果展示

- 使用 `NSOutlineView` 显示分组结构
- 每组显示：文件大小、重复数量、路径
- 支持展开/折叠查看组内文件

#### C. 批量操作

- 每组提供"保留最新"和"全部删除"按钮
- 删除前显示确认对话框，列出待删除文件
- 调用 CoreBridge.deleteFile 逐个删除

#### D. 回调解析

- 在 DuplicateScanBridge 中实现 `dedupGroupCallback`，解析 FFDuplicateGroup C 结构体
- 结构体字段：id, hash, size, files（数组）

### 4.3 需要修改的文件

| 文件 | 改动 |
|------|------|
| `DuplicateScanView.swift` | 实现完整 UI：目录选择、进度条、结果表格、操作按钮 |
| `SearchBridge.swift` | 实现 dedupGroupCallback，解析 FFDuplicateGroup |
| `MainWindowController.swift` | 确保 showDuplicateScan 正确连接 DuplicateScanBridge |

---

## 5. 第四节：实施顺序与里程碑

### Week 1：文件浏览/管理路径打通

- Day 1-2：实现 SidebarView 目录树
- Day 3：添加面包屑导航
- Day 4：接入 QuickLook 空格预览
- Day 5：联调验证

### Week 2：搜索路径打通

- Day 1-2：实现 SearchBridge 回调解析
- Day 3：连接 SearchBarView 和 SearchResultsView
- Day 4：添加搜索结果双击定位和右键菜单
- Day 5：联调验证

### Week 3：重复扫描路径打通

- Day 1-2：实现 DuplicateScanView 完整 UI
- Day 3：实现 dedupGroupCallback 解析
- Day 4：添加保留/删除操作
- Day 5：联调验证

### Week 4：集成测试与 Beta 准备

- Day 1-2：三条路径端到端测试
- Day 3：错误处理完善（权限拒绝、路径不存在、网络中断）
- Day 4：打包验证（生成 .app，检查依赖）
- Day 5：Beta 发布准备

---

## 6. 第五节：与原设计文档的一致性检查

| 原设计决策 | 本方案实现方式 | 一致性 |
|-----------|--------------|--------|
| Quick Look 空格预览 | 复用 SearchBridge 中的 QuickLookBridge | ✅ 一致 |
| Spotlight 搜索（阶段5） | 使用 Rust `ff_search`（基于内存过滤，非 Spotlight） | ⚠️ 简化版，beta 后升级 |
| FSEvents 实时监听（阶段5） | 延后至 beta 后 | ⚠️ 延后 |
| 缩略图引擎（阶段2） | 延后至 beta 后 | ⚠️ 延后 |
| 任务调度中心（阶段3） | 延后至 beta 后 | ⚠️ 延后 |
| 网络韧性（阶段4） | 延后至 beta 后 | ⚠️ 延后 |

**说明**：搜索功能在原设计中计划使用 Spotlight + FSEvents（阶段5），但当前 Rust Core 已实现基于内存过滤的 `search_engine.rs`。Beta 阶段先使用现有实现，后续迭代再升级到 Spotlight。

---

## 7. 风险与缓解

### 7.1 回调解析复杂度

**风险**：Rust FFI 回调中的 C 结构体解析可能涉及复杂的内存管理。

**缓解**：
- 在 SearchBridge 和 DuplicateScanBridge 中实现最小可行解析器
- 使用 `UnsafeRawPointer` 和 `withMemoryRebound` 安全访问 C 结构体
- 先处理简单场景（单文件路径），复杂场景后续迭代

### 7.2 目录树性能

**风险**：大目录（万级文件）下构建目录树可能卡顿 UI。

**缓解**：
- 侧边栏使用异步加载，只展开时加载子目录
- 限制初始加载深度（如只加载第一层）
- 使用 `DispatchQueue.global()` 后台构建目录树

### 7.3 重复扫描内存占用

**风险**：扫描大目录时，Rust 端可能积累大量重复组数据。

**缓解**：
- 使用流式回调，边扫描边返回结果
- Swift 端收到回调后立即更新 UI，不缓存全部结果
- 提供"取消扫描"按钮，调用 `ff_cancel_scan`

---

## 8. 待确认事项

1. **搜索结果定位**：双击搜索结果时，是打开新窗口定位，还是在当前窗口加载目录并高亮？
2. **重复扫描默认目录**：默认扫描当前目录，还是让用户选择？
3. **删除确认方式**：使用系统 Alert，还是自定义面板？
4. **侧边栏初始状态**：默认展开常用目录（如桌面、文档），还是从根目录开始？

---

Spec 已写入 `/docs/superpowers/specs/2026-07-18-beta-ui-completion-design.md`。

请审查这份设计文档，如有需要修改或补充的地方请告诉我。确认后我将开始按计划实施。
