# 变更日志

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/) 规范。

---

## [0.6.0-alpha] — 2026-07-21

> 🎉 FlowFinder 首个原生版本发布！从 Tauri + React 完整重构为 Swift & AppKit + Rust Core 架构。

### ✨ 新功能

#### 核心架构
- **Swift & AppKit 原生 UI**：完全重写 UI 层，使用 NSTableView、NSCollectionView、NSSplitView、NSMenu 原生组件
- **Rust Core FFI 桥接**：Rust Core 编译为 cdylib，通过 C ABI 暴露接口，Swift 通过 Bridging Header 调用
- **NSVisualEffectView 毛玻璃**：系统级毛玻璃材质，自动跟随深浅色主题，替代 WebView CSS backdrop-filter

#### 文件浏览
- **双栏布局**：左右独立导航，NSSplitView 可拖拽分隔条
- **统一工具栏**：后退 / 前进 / 上一级、面包屑路径、正则搜索栏、视图切换按钮，嵌入标题栏
- **双视图模式**：表格视图（NSTableView，可拖列宽 + 点击排序）+ 网格视图（NSCollectionView + 缩略图）
- **文件详情栏**：选中文件时底部显示缩略图、类型、大小、修改日期、标签等信息
- **隐藏 / 系统文件显示**：隐藏文件灰色文字，系统保护文件红色文字，可切换显示

#### 跨面板文件操作
- **复制到对侧面板**：⌘⇧C 一键复制选中文件到对侧面板当前目录
- **移动到对侧面板**：⌘⇧X 一键移动选中文件到对侧面板当前目录
- **在对侧面板打开**：右键菜单在文件夹上可直接在对侧面板打开该目录
- **冲突自动解决**：同名文件自动追加「副本 N」后缀
- **面板激活**：点击面板任意空白区域即激活该面板，无需键盘 Tab 切换

#### 原生右键菜单
- **FileListView 右键菜单**：打开、复制、剪切、粘贴、跨面板操作、重命名、删除、新建文件夹
- **FileGridView 右键菜单**：与 FileListView 一致的完整右键菜单
- **菜单栏快捷键**：完整的 ⌘C / ⌘X / ⌘V / ⌘⇧C / ⌘⇧X / ⌘N / Delete 等快捷键支持

#### macOS 原生体验
- **Quick Look 预览**：QLPreviewPanel 原生浮动预览，空格键触发
- **混合缩略图引擎**：QLThumbnailGenerator + SQLite 缓存，P0/P1 双队列优先级
- **Spotlight 搜索**：NSMetadataQuery 异步搜索 + Channel 流式推送结果
- **FSEvents 实时监控**：文件系统变更自动刷新目录列表
- **getattrlistbulk 批量读取**：单次系统调用获取目录全部元数据，性能提升 10-30 倍
- **clonefile CoW 复制**：APFS 卷零拷贝文件复制，瞬时完成
- **原生拖拽**：NSDraggingSource/Destination，同卷移动、跨卷复制、Cmd 键切换

#### 侧边栏
- **个人收藏**：任意文件夹可拖拽添加到收藏夹
- **存储设备**：磁盘分组显示，自动排除系统隐藏卷，支持 SMB/UNC 网络挂载
- **标签管理**：标签分类树，颜色圆点标识，AI 标签与 macOS 原生标签双向同步
- **可折叠区段**：所有区段可折叠，状态持久化

#### 高级功能
- **BLAKE3 重复文件检测**：三阶段检测（大小分组 → 部分哈希 → 完整哈希），实时进度流
- **AI 智能打标**：支持 OpenAI / Claude / Ollama / 自定义 API，隐私隔离（仅发送文件名 + 扩展名）
- **任务调度中心**：统一管理复制 / 移动 / 删除 / 查重任务，支持暂停 / 恢复 / 取消
- **SMB 网络共享**：渐进式加载、LRU 目录缓存、rayon 并行操作、断连自动重连
- **设置面板**：通用设置、外观主题（深色 / 浅色 / 跟随系统）、AI 模型配置

### 🚀 性能提升

| 指标 | 原版（Tauri） | 新版（Native） | 提升 |
|------|--------------|----------------|------|
| 目录列表（冷） | ~15-30 ms | ~0.5-1.0 ms | 10-30x |
| 目录列表（热） | ~5-10 ms | ~0.2-0.5 ms | 10-20x |
| 内存占用 | ~50-100 MB | ~20-30 MB | 2-3x |
| 启动时间 | ~2-3s | ~0.5s | 4-6x |
| 二进制大小 | ~80-100 MB | ~15-20 MB | 5-6x |

### 🏗️ 架构变更

- UI 层从 React 19 + WebView 重写为 Swift 5.9 + AppKit
- 文件列表从 react-virtual 重写为 NSTableView + NSCollectionView
- 缩略图从 Rust FFI 重写为 QLThumbnailGenerator（Swift 原生）
- QuickLook 从 Swift Bridge 中转重写为 QLPreviewPanel 单例直调
- 搜索从 Tauri Commands 重写为 SearchBridge + SpotlightBridge
- 拖拽从 HTML5 重写为 NSDraggingSource/Destination
- 毛玻璃从 CSS backdrop-filter 重写为 NSVisualEffectView

### 📦 下载

| 文件 | 大小 | 架构 | 说明 |
|------|------|------|------|
| `FlowFinder-0.6.0-alpha.dmg` | ~1.7 MB | Apple Silicon | DMG 安装镜像 |
| `FlowFinder-0.6.0-alpha.zip` | ~1.2 MB | Apple Silicon | ZIP 压缩包（含 .app） |
| `libflowfinder_core.dylib` | — | Apple Silicon | Rust Core 动态库（开发用） |
| `ff_ffi.h` | — | — | FFI C 头文件（开发用） |

### ⚠️ 已知限制

- 仅支持 Apple Silicon 架构（Intel Mac 未充分测试）
- 当前为 alpha 版本，可能存在未发现的 Bug
- 部分 UI 动画仍在优化中
- 全局撤销 / 重做栈尚未完整实现
- 批量重命名 UI 尚在开发中

### 📝 完整重构历史

详见 [重构日志](docs/MIGRATION_LOG.md)。

---

## 版本号规则

FlowFinder 采用以下版本号规则：

- **0.x.0-alpha** / **0.x.0-beta**：开发预览版，功能可能不完整
- **0.x.0**：稳定版，核心功能完整
- **1.0.0**：正式发布版，通过全面测试

无重大架构变更时，后续版本依次递增（0.6.1、0.6.2 ...）。
