# Tasks

## P0 - 阻塞性修复（必须优先完成）

- [x] Task 1: 修复 ff_volume_mount 签名不匹配（编译阻塞）
  - 修复 Rust 侧 `volumes.rs:539` 的 `ff_volume_mount` 签名，接受 `(path: *const c_char, options: *const c_char)` 两个参数，或修改 Swift 侧 `CoreBridge.swift:1221` 只传一个参数
  - 对齐 `ff_ffi.h` 头文件声明
  - 验证：`cargo check` + `xcodebuild build` 均通过

- [x] Task 2: 修复 FSEvents 回调空壳
  - 实现 `CoreBridge.swift` 的 `fseventsCallback`：解析 path 并调用 `changeHandler`
  - `startFSEventsWatcher` 传入真实的 user_data（持有 changeHandler 闭包的上下文）
  - `stopFSEventsWatcher` 存储并使用真实的 watcher handle（不再硬编码 0）
  - 验证：在外部 Finder 创建文件，FlowFinder 列表自动刷新

- [x] Task 3: 对齐 FFI 签名（ff_task_submit / ff_task_cancel / ff_volume_info）
  - `ff_task_submit`：修改 Rust 和 Swift 两侧，使 submitTask 返回 task ID
  - `ff_task_cancel`：统一为字符串 task_id（与 FFI header 一致）
  - `ff_volume_info`：统一为输出参数式或回调式
  - 对齐 `ff_ffi.h` 头文件
  - 验证：`cargo check` + `xcodebuild build` 均通过

## P1 - 功能补齐（核心体验差距）

- [x] Task 4: FileGridView 拖拽实现
  - 为 FileGridView 添加 `NSDraggingSource`（拖出文件到其他应用）
  - 添加 `NSDraggingDestination`（接收拖入，同卷移动/跨卷复制）
  - 复用 FileListView 的 `isSameVolume` / `isMoveOperation` 逻辑
  - 验证：网格视图可拖拽文件到桌面/对侧面板

- [x] Task 5: Enter 键改为 inline rename
  - FileListView 中 Enter 键触发内联重命名（NSTableView 的 viewBased 编辑模式）
  - 目录/文件均可重命名
  - 原 Enter 打开行为改由双击或 ⌘O 触发
  - 验证：选中文件按 Enter 进入编辑模式，输入新名称按 Enter 确认

- [x] Task 6: 侧边栏标签/收藏夹 CRUD UI 入口
  - 收藏夹：右键菜单添加"添加到收藏夹"（文件列表右键 + 侧边栏"+"按钮）
  - 标签：侧边栏标签区添加"+"按钮，弹出创建标签对话框（名称+颜色选择）
  - 标签右键菜单添加"删除标签"
  - 验证：可通过 UI 添加/删除收藏夹和标签

- [x] Task 7: 侧边栏三区域独立遮罩
  - 将收藏夹和标签拆分为两个独立的 `GlassSectionMaskView`
  - 确认三个区域各自有独立圆角遮罩和间距
  - 验证：侧边栏三个区域视觉上各自独立

## P2 - 架构完善（已实现但未接入）

- [ ] Task 8: 接入 sqlite_cache 到 FFI
  - 修改 `ff_cache_get`/`ff_cache_put` 调用 `sqlite_cache::cache_get`/`cache_put`
  - 或新增 `ff_sqlite_cache_get`/`ff_sqlite_cache_put` FFI 函数
  - 保留 `dir_cache` 内存缓存作为一级缓存
  - 验证：`cargo test` + 目录缓存持久化到磁盘

- [x] Task 9: 接入 parallel_ops 到 FFI
  - 新增 `ff_parallel_copy`/`ff_parallel_move`/`ff_parallel_delete` FFI 函数
  - Swift 侧 CoreBridge 添加对应调用
  - 批量文件操作改用并行版本
  - 验证：批量复制 100 个文件使用 4 线程并行

- [ ] Task 10: 清理 dedup_engine.rs MD5 注释残留
  - 将 4 处 MD5 注释更新为 blake3
  - 验证：代码搜索 "MD5" 在 rust-core 中仅返回历史提及

## P3 - 新功能开发

- [ ] Task 11: 全局撤销/重做栈
  - 创建 UndoManager 集成
  - 文件操作（移动/复制/重命名/删除）注册撤销动作
  - Edit 菜单"撤销"/"重做"连接到 UndoManager
  - 验证：移动文件后 ⌘Z 撤销，文件回到原位

- [ ] Task 12: 批量重命名 UI
  - 创建批量重命名面板（模式替换/序号添加/大小写转换）
  - 选中多个文件后通过菜单/快捷键触发
  - 预览重命名结果
  - 验证：选中 10 个文件，批量添加序号前缀

- [ ] Task 13: Release 构建和 DMG 打包脚本
  - 创建 `scripts/package.sh`：Release 编译 + .app bundle 组装 + codesign + DMG 打包
  - 验证：`scripts/package.sh` 产出可分发的 .dmg 文件

- [ ] Task 14: AI 标签生成
  - Rust Core 添加标签分类引擎（基于文件名+扩展名的规则分类）
  - FFI 暴露 `ff_generate_tags` 函数
  - Swift 侧 UI：选中文件 -> 右键"AI 自动打标签" -> 调用分类引擎 -> 写入 xattr
  - 验证：选中图片文件，自动打上"图片"标签

## Task Dependencies

- Task 3 依赖 Task 1（FFI 签名统一修复）
- Task 8 和 Task 9 互相独立，可并行
- Task 11 依赖 Task 3（撤销栈需要 task ID 跟踪）
- Task 14 依赖 Task 6（标签 CRUD UI 入口）
- Task 4, 5, 6, 7 互相独立，可并行
