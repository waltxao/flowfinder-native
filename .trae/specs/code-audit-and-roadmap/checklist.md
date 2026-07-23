# 审计验证检查清单

## P0 阻塞性修复验证

- [x] ff_volume_mount 签名修复后，`cargo check` 和 `xcodebuild build` 均无错误
- [x] FSEvents 回调实现后，外部 Finder 创建文件时 FlowFinder 列表自动刷新
- [x] FFI 签名（ff_task_submit / ff_task_cancel / ff_volume_info）与 ff_ffi.h 完全一致
- [x] submitTask 返回 task ID 字符串
- [x] cancelTask 接受字符串 task_id 参数

## P1 功能补齐验证

- [x] FileGridView 支持拖出文件到桌面（NSDraggingSource）
- [x] FileGridView 支持接收拖入文件（NSDraggingDestination）
- [x] FileGridView 拖拽时同卷移动、跨卷复制、Cmd 键切换
- [x] FileListView 中 Enter 键触发内联重命名编辑模式
- [x] 重命名输入新名称后按 Enter 确认，文件名更新
- [x] 文件列表右键菜单包含"添加到收藏夹"选项
- [x] 侧边栏标签区有"+"按钮可创建新标签
- [x] 标签右键菜单包含"删除标签"选项
- [x] 侧边栏收藏夹、标签、存储设备三个区域各自有独立圆角遮罩

## P2 架构完善验证

- [x] ff_cache_get / ff_cache_put 使用 sqlite_cache 模块（或新增独立 FFI）
- [x] 目录缓存数据持久化到 SQLite 数据库文件
- [x] ff_parallel_copy / ff_parallel_move / ff_parallel_delete FFI 函数存在且可调用
- [x] 批量文件操作使用 rayon 并行（4 线程）
- [x] dedup_engine.rs 中无 "MD5" 注释残留（仅 blake3）

## P3 新功能验证

- [ ] 文件移动后 ⌘Z 撤销，文件回到原位
- [ ] 文件重命名后 ⌘Z 撤销，名称恢复
- [ ] 批量重命名面板可预览重命名结果
- [ ] 批量重命名支持模式替换、序号添加、大小写转换
- [ ] scripts/package.sh 产出可分发的 .dmg 文件
- [ ] AI 标签生成：选中文件后可自动打标签
- [ ] 自动打的标签写入 xattr（com.flowfinder.tags）

## 代码质量验证

- [x] `cargo check` 零错误（警告可接受）
- [x] `xcodebuild build` 零错误
- [x] `cargo test` 全部通过
- [ ] 代码中无 TODO/FIXME 标记的阻塞性问题
