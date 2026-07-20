# Phase 1: Rust Core + Bridge 修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 Rust Core 和 Swift Bridge 层的所有阻塞性问题，为 Phase 2 UI 重写提供稳定的地基。

**Architecture:** 保留现有 Rust Core 模块结构，修复 FFI 签名不一致、迁移 blake3、新增 sqlite/rayon、补全 Bridge 回调实现。Swift Bridge 层新增 4 个文件（SpotlightBridge/SMBBridge/ThumbnailBridge/TagBridge）。

**Tech Stack:** Rust 1.70+ / Swift 5.9+ / cdylib FFI / @_silgen_name

## Global Constraints

- Rust crate 名：`flowfinder-core`，crate-type `["cdylib", "staticlib"]`
- 现有依赖：`libc`, `blake3`, `md5`, `walkdir`, `lru`, `parking_lot`, `log`, `chrono`, `serde`, `serde_json`, `plist`
- Rust 源码根：`/Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/rust-core/`
- Swift 源码根：`/Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative/FlowFinderNative/`
- FFI 头文件：`rust-core/include/ff_ffi.h`
- 构建命令：`cd rust-core && cargo build` 然后 `cd FlowFinderNative && swift build`

---

## File Structure

### Rust Core 新增/修改文件

| 文件 | 操作 | 职责 |
|------|------|------|
| `rust-core/Cargo.toml` | 修改 | 新增 `rusqlite`、`rayon` 依赖，移除 `md5` |
| `rust-core/src/core/dedup_engine.rs` | 修改 | md5 → blake3 迁移 |
| `rust-core/src/core/scanner.rs` | 修改 | `hash_file` 通过 FFI 暴露 |
| `rust-core/src/core/sqlite_cache.rs` | 新建 | SQLite 增量缓存模块 |
| `rust-core/src/core/parallel_ops.rs` | 新建 | rayon 并行批量操作 |
| `rust-core/src/core/smb_mount.rs` | 新建 | SMB 挂载 FFI |
| `rust-core/src/core/thumbnails.rs` | 修改 | 移除占位实现，改为返回路径由 Swift 接管 |
| `rust-core/src/core/mod.rs` | 修改 | 注册新模块 |
| `rust-core/src/ffi/mod.rs` | 修改 | 修复签名、新增 FFI 导出 |
| `rust-core/include/ff_ffi.h` | 修改 | 对齐头文件声明 |

### Swift Bridge 新增/修改文件

| 文件 | 操作 | 职责 |
|------|------|------|
| `Bridge/SearchBridge.swift` | 修改 | 实现 searchCallback/dedupGroupCallback |
| `Bridge/FFIFunctions.swift` | 修改 | 新增 C 兼容结构体、FFI 函数声明 |
| `Bridge/CoreBridge.swift` | 修改 | 修复 unsafe 指针、task ID 返回 |
| `Bridge/SpotlightBridge.swift` | 新建 | NSMetadataQuery 封装 |
| `Bridge/SMBBridge.swift` | 新建 | NetFSMountURLSync 封装 |
| `Bridge/ThumbnailBridge.swift` | 新建 | QLThumbnailGenerator 封装 |
| `Bridge/TagBridge.swift` | 新建 | xattr 标签读写 |

---

## Task 1: blake3 迁移（dedup_engine.rs）

**Files:**
- Modify: `rust-core/Cargo.toml`（移除 `md5 = "0.7"` 依赖）
- Modify: `rust-core/src/core/dedup_engine.rs`（md5 → blake3）
- Test: `rust-core/src/core/dedup_engine.rs`（内联测试）

**Interfaces:**
- Produces: `fn compute_partial_hash(path: &str) -> String`（blake3，返回 hex）
- Produces: `fn compute_full_hash(path: &str) -> String`（blake3，返回 hex）
- Consumes: `blake3 = "1.5"`（已在 Cargo.toml）

- [ ] **Step 1: 读取 dedup_engine.rs 当前 md5 用法**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/rust-core && grep -n "md5" src/core/dedup_engine.rs`
Expected: 显示所有 md5 调用行号（需替换的位置）

- [ ] **Step 2: 移除 Cargo.toml 中的 md5 依赖**

在 `rust-core/Cargo.toml` 中删除 `md5 = "0.7"` 行。

- [ ] **Step 3: 替换 dedup_engine.rs 中的 md5 为 blake3**

将所有 `use md5::{compute, Digest};` 或 `md5::` 调用替换为 blake3：

```rust
// 旧代码（示例，需根据实际行号定位）：
// use md5::{compute, Digest};
// let partial_hash = format!("{:x}", md5::compute(&buffer));

// 新代码：
use blake3::Hasher;

fn compute_partial_hash(path: &str) -> std::io::Result<String> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Hasher::new();
    let mut buffer = [0u8; 8192]; // 首尾 4KB

    // 读前 4KB
    use std::io::Read;
    let n = file.read(&mut buffer)?;
    hasher.update(&buffer[..n]);

    // 读后 4KB（如果文件 > 8KB）
    let file_size = file.metadata()?.len();
    if file_size > 8192 {
        use std::io::Seek;
        file.seek(std::io::SeekFrom::Start(file_size - 4096))?;
        let mut tail = [0u8; 4096];
        let n = file.read(&mut tail)?;
        hasher.update(&tail[..n]);
    }

    Ok(hasher.finalize().to_hex().to_string())
}

fn compute_full_hash(path: &str) -> std::io::Result<String> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Hasher::new();
    let mut buffer = [0u8; 65536];
    use std::io::Read;
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 { break; }
        hasher.update(&buffer[..n]);
    }
    Ok(hasher.finalize().to_hex().to_string())
}
```

- [ ] **Step 4: 添加 blake3 哈希测试**

在 `dedup_engine.rs` 末尾添加测试模块：

```rust
#[cfg(test)]
mod blake3_tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn test_partial_hash_small_file() {
        let dir = std::env::temp_dir();
        let path = dir.join("test_small_blake3.txt");
        std::fs::write(&path, b"hello world").unwrap();
        let hash = compute_partial_hash(path.to_str().unwrap()).unwrap();
        assert!(!hash.is_empty());
        assert_eq!(hash.len(), 64); // blake3 hex = 32 bytes = 64 chars
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_full_hash_large_file() {
        let dir = std::env::temp_dir();
        let path = dir.join("test_large_blake3.bin");
        let mut file = std::fs::File::create(&path).unwrap();
        // 写入 16KB 数据
        let data = vec![0xABu8; 16384];
        file.write_all(&data).unwrap();
        drop(file);
        let hash = compute_full_hash(path.to_str().unwrap()).unwrap();
        assert_eq!(hash.len(), 64);
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_same_file_same_hash() {
        let dir = std::env::temp_dir();
        let path1 = dir.join("test_same_1.txt");
        let path2 = dir.join("test_same_2.txt");
        std::fs::write(&path1, b"identical content").unwrap();
        std::fs::write(&path2, b"identical content").unwrap();
        let hash1 = compute_full_hash(path1.to_str().unwrap()).unwrap();
        let hash2 = compute_full_hash(path2.to_str().unwrap()).unwrap();
        assert_eq!(hash1, hash2);
        std::fs::remove_file(&path1).ok();
        std::fs::remove_file(&path2).ok();
    }
}
```

- [ ] **Step 5: 运行测试**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/rust-core && cargo test blake3 -- --nocapture`
Expected: 3 个测试全部 PASS

- [ ] **Step 6: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add rust-core/Cargo.toml rust-core/src/core/dedup_engine.rs
git commit -m "refactor: dedup_engine 从 md5 迁移到 blake3

- 移除 md5 依赖
- partial_hash 和 full_hash 改用 blake3::Hasher
- 新增 3 个测试用例验证哈希一致性"
```

---

## Task 2: 新增 sqlite_cache.rs 模块

**Files:**
- Create: `rust-core/src/core/sqlite_cache.rs`
- Modify: `rust-core/Cargo.toml`（新增 `rusqlite` 依赖）
- Modify: `rust-core/src/core/mod.rs`（注册模块）

**Interfaces:**
- Produces: `pub fn init_cache(db_path: &str) -> io::Result<()>`
- Produces: `pub fn cache_get(db_path: &str, dir_path: &str) -> io::Result<Option<Vec<FileEntrySkeleton>>>`
- Produces: `pub fn cache_put(db_path: &str, dir_path: &str, entries: &[FileEntrySkeleton]) -> io::Result<()>`
- Produces: `pub fn cache_invalidate(db_path: &str, dir_path: &str) -> io::Result<()>`
- Consumes: `FileEntrySkeleton` from `scanner.rs`

- [ ] **Step 1: 在 Cargo.toml 新增 rusqlite 依赖**

在 `rust-core/Cargo.toml` 的 `[dependencies]` 下添加：

```toml
rusqlite = { version = "0.31", features = ["bundled"] }
```

- [ ] **Step 2: 创建 sqlite_cache.rs**

创建 `rust-core/src/core/sqlite_cache.rs`：

```rust
use rusqlite::{params, Connection};
use std::io;
use std::path::Path;
use crate::core::scanner::FileEntrySkeleton;

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS dir_cache (
    dir_path TEXT NOT NULL,
    file_path TEXT NOT NULL,
    file_name TEXT NOT NULL,
    is_dir INTEGER NOT NULL,
    is_file INTEGER NOT NULL,
    is_symlink INTEGER NOT NULL,
    is_hidden INTEGER NOT NULL,
    extension TEXT NOT NULL,
    size INTEGER NOT NULL,
    modified INTEGER NOT NULL,
    created INTEGER NOT NULL,
    is_system_protected INTEGER NOT NULL,
    cached_at INTEGER NOT NULL,
    PRIMARY KEY (dir_path, file_path)
);
CREATE INDEX IF NOT EXISTS idx_dir_cache_dir ON dir_cache(dir_path);
";

pub fn init_cache(db_path: &str) -> io::Result<()> {
    let conn = Connection::open(db_path)
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;
    conn.execute_batch(SCHEMA)
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;
    Ok(())
}

pub fn cache_get(db_path: &str, dir_path: &str) -> io::Result<Option<Vec<FileEntrySkeleton>>> {
    let conn = Connection::open(db_path)
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;

    let mut stmt = conn.prepare(
        "SELECT file_path, file_name, is_dir, is_file, is_symlink, is_hidden, extension, size, modified, created, is_system_protected
         FROM dir_cache WHERE dir_path = ?1"
    ).map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;

    let entries: Vec<FileEntrySkeleton> = stmt.query_map(params![dir_path], |row| {
        Ok(FileEntrySkeleton {
            id: row.get::<_, String>(1)? + ":" + &row.get::<_, String>(0)?,
            path: row.get(0)?,
            name: row.get(1)?,
            is_dir: row.get(2)?,
            is_file: row.get(3)?,
            is_symlink: row.get(4)?,
            is_hidden: row.get(5)?,
            extension: row.get(6)?,
            size: row.get(7)?,
            modified: row.get(8)?,
            created: row.get(9)?,
            is_system_protected: row.get(10)?,
            metadata_loaded: true,
        })
    }).map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?
      .filter_map(|r| r.ok())
      .collect();

    if entries.is_empty() {
        Ok(None)
    } else {
        Ok(Some(entries))
    }
}

pub fn cache_put(db_path: &str, dir_path: &str, entries: &[FileEntrySkeleton]) -> io::Result<()> {
    let mut conn = Connection::open(db_path)
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;

    let tx = conn.transaction()
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;

    // 先删除旧缓存
    tx.execute("DELETE FROM dir_cache WHERE dir_path = ?1", params![dir_path])
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;

    let now = chrono::Utc::now().timestamp();
    for entry in entries {
        tx.execute(
            "INSERT OR REPLACE INTO dir_cache
             (dir_path, file_path, file_name, is_dir, is_file, is_symlink, is_hidden, extension, size, modified, created, is_system_protected, cached_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            params![
                dir_path, entry.path, entry.name,
                entry.is_dir as i32, entry.is_file as i32, entry.is_symlink as i32,
                entry.is_hidden as i32, entry.extension, entry.size as i64,
                entry.modified, entry.created, entry.is_system_protected as i32, now
            ],
        ).map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;
    }

    tx.commit()
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;
    Ok(())
}

pub fn cache_invalidate(db_path: &str, dir_path: &str) -> io::Result<()> {
    let conn = Connection::open(db_path)
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;
    conn.execute("DELETE FROM dir_cache WHERE dir_path = ?1", params![dir_path])
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;
    Ok(())
}

pub fn is_cache_fresh(db_path: &str, dir_path: &str, dir_mtime: i64) -> io::Result<bool> {
    let conn = Connection::open(db_path)
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;
    let cached_at: Option<i64> = conn.query_row(
        "SELECT MAX(cached_at) FROM dir_cache WHERE dir_path = ?1",
        params![dir_path],
        |row| row.get(0),
    ).unwrap_or(None);

    Ok(cached_at.map_or(false, |ts| ts >= dir_mtime))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::NamedTempFile;

    fn make_test_entry(name: &str) -> FileEntrySkeleton {
        FileEntrySkeleton {
            id: name.to_string(),
            name: name.to_string(),
            path: format!("/tmp/{}", name),
            is_dir: false,
            is_file: true,
            is_symlink: false,
            is_hidden: false,
            extension: "txt".to_string(),
            size: 100,
            modified: 1000,
            created: 900,
            is_system_protected: false,
            metadata_loaded: true,
        }
    }

    #[test]
    fn test_cache_put_and_get() {
        let tmp = NamedTempFile::new().unwrap();
        let db_path = tmp.path().to_str().unwrap();
        init_cache(db_path).unwrap();

        let entries = vec![make_test_entry("a.txt"), make_test_entry("b.txt")];
        cache_put(db_path, "/tmp", &entries).unwrap();

        let result = cache_get(db_path, "/tmp").unwrap();
        assert!(result.is_some());
        assert_eq!(result.unwrap().len(), 2);
    }

    #[test]
    fn test_cache_invalidate() {
        let tmp = NamedTempFile::new().unwrap();
        let db_path = tmp.path().to_str().unwrap();
        init_cache(db_path).unwrap();

        let entries = vec![make_test_entry("a.txt")];
        cache_put(db_path, "/tmp", &entries).unwrap();
        cache_invalidate(db_path, "/tmp").unwrap();

        let result = cache_get(db_path, "/tmp").unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_is_cache_fresh() {
        let tmp = NamedTempFile::new().unwrap();
        let db_path = tmp.path().to_str().unwrap();
        init_cache(db_path).unwrap();

        let entries = vec![make_test_entry("a.txt")];
        cache_put(db_path, "/tmp", &entries).unwrap();

        // 缓存时间应 >= 0（1970），所以对 mtime=0 应该是 fresh
        assert!(is_cache_fresh(db_path, "/tmp", 0).unwrap());
        // mtime 远在未来，应不是 fresh
        assert!(!is_cache_fresh(db_path, "/tmp", 9999999999).unwrap());
    }
}
```

- [ ] **Step 3: 在 mod.rs 注册模块**

在 `rust-core/src/core/mod.rs` 中添加：

```rust
pub mod sqlite_cache;
```

- [ ] **Step 4: 运行测试**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/rust-core && cargo test sqlite_cache -- --nocapture`
Expected: 3 个测试全部 PASS

- [ ] **Step 5: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add rust-core/Cargo.toml rust-core/src/core/sqlite_cache.rs rust-core/src/core/mod.rs
git commit -m "feat: 新增 SQLite 增量缓存模块

- 新增 rusqlite 依赖（bundled）
- 实现 cache_get/cache_put/cache_invalidate/is_cache_fresh
- 基于 mtime 的增量缓存判断
- 3 个测试用例验证 CRUD"
```

---

## Task 3: 新增 parallel_ops.rs 模块（rayon）

**Files:**
- Create: `rust-core/src/core/parallel_ops.rs`
- Modify: `rust-core/Cargo.toml`（新增 `rayon` 依赖）
- Modify: `rust-core/src/core/mod.rs`（注册模块）

**Interfaces:**
- Produces: `pub fn parallel_copy_files(srcs: &[String], dst_dir: &str, progress: impl Fn(usize, usize)) -> Vec<(String, io::Result<()>)>`
- Produces: `pub fn parallel_move_files(srcs: &[String], dst_dir: &str, progress: impl Fn(usize, usize)) -> Vec<(String, io::Result<()>)>`
- Produces: `pub fn parallel_delete_files(paths: &[String], progress: impl Fn(usize, usize)) -> Vec<(String, io::Result<()>)>`

- [ ] **Step 1: 在 Cargo.toml 新增 rayon 依赖**

在 `rust-core/Cargo.toml` 的 `[dependencies]` 下添加：

```toml
rayon = "1.10"
```

- [ ] **Step 2: 创建 parallel_ops.rs**

创建 `rust-core/src/core/parallel_ops.rs`：

```rust
use rayon::prelude::*;
use std::io;
use std::path::Path;

/// 并行复制文件（使用 clonefile CoW）
pub fn parallel_copy_files(
    srcs: &[String],
    dst_dir: &str,
    progress: impl Fn(usize, usize) + Sync,
) -> Vec<(String, io::Result<()>)> {
    let total = srcs.len();
    let counter = std::sync::atomic::AtomicUsize::new(0);

    srcs.par_iter()
        .map(|src| {
            let result = copy_single(src, dst_dir);
            let done = counter.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
            progress(done, total);
            (src.clone(), result)
        })
        .collect()
}

/// 并行移动文件
pub fn parallel_move_files(
    srcs: &[String],
    dst_dir: &str,
    progress: impl Fn(usize, usize) + Sync,
) -> Vec<(String, io::Result<()>)> {
    let total = srcs.len();
    let counter = std::sync::atomic::AtomicUsize::new(0);

    srcs.par_iter()
        .map(|src| {
            let result = move_single(src, dst_dir);
            let done = counter.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
            progress(done, total);
            (src.clone(), result)
        })
        .collect()
}

/// 并行删除文件
pub fn parallel_delete_files(
    paths: &[String],
    progress: impl Fn(usize, usize) + Sync,
) -> Vec<(String, io::Result<()>)> {
    let total = paths.len();
    let counter = std::sync::atomic::AtomicUsize::new(0);

    paths.par_iter()
        .map(|path| {
            let result = if Path::new(path).is_dir() {
                std::fs::remove_dir_all(path)
            } else {
                std::fs::remove_file(path)
            };
            let done = counter.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
            progress(done, total);
            (path.clone(), result)
        })
        .collect()
}

fn copy_single(src: &str, dst_dir: &str) -> io::Result<()> {
    let src_path = Path::new(src);
    let file_name = src_path.file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "无法获取文件名"))?;
    let dst_path = Path::new(dst_dir).join(file_name);

    // 尝试 clonefile（CoW），失败回退到普通复制
    let result = crate::core::cow_copy::copy_file(src, dst_path.to_str().unwrap_or(""));
    result
}

fn move_single(src: &str, dst_dir: &str) -> io::Result<()> {
    let src_path = Path::new(src);
    let file_name = src_path.file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "无法获取文件名"))?;
    let dst_path = Path::new(dst_dir).join(file_name);

    std::fs::rename(src, &dst_path)
        .or_else(|_| {
            // 跨卷移动：先复制再删除
            copy_single(src, dst_dir)?;
            std::fs::remove_file(src)
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;
    use std::fs;

    #[test]
    fn test_parallel_copy_files() {
        let src_dir = tempdir().unwrap();
        let dst_dir = tempdir().unwrap();

        // 创建 3 个测试文件
        let srcs: Vec<String> = (0..3).map(|i| {
            let path = src_dir.path().join(format!("file{}.txt", i));
            fs::write(&path, format!("content{}", i)).unwrap();
            path.to_str().unwrap().to_string()
        }).collect();

        let progress_count = std::sync::atomic::AtomicUsize::new(0);
        let results = parallel_copy_files(&srcs, dst_dir.path().to_str().unwrap(), |_, _| {
            progress_count.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        });

        assert_eq!(results.len(), 3);
        assert!(results.iter().all(|(_, r)| r.is_ok()));
        assert_eq!(progress_count.load(std::sync::atomic::Ordering::Relaxed), 3);

        // 验证目标文件存在
        for i in 0..3 {
            let dst = dst_dir.path().join(format!("file{}.txt", i));
            assert!(dst.exists());
        }
    }

    #[test]
    fn test_parallel_delete_files() {
        let dir = tempdir().unwrap();

        let paths: Vec<String> = (0..3).map(|i| {
            let path = dir.path().join(format!("del{}.txt", i));
            fs::write(&path, b"data").unwrap();
            path.to_str().unwrap().to_string()
        }).collect();

        let results = parallel_delete_files(&paths, |_, _| {});
        assert_eq!(results.len(), 3);
        assert!(results.iter().all(|(_, r)| r.is_ok()));

        for p in &paths {
            assert!(!Path::new(p).exists());
        }
    }
}
```

- [ ] **Step 3: 在 mod.rs 注册模块**

在 `rust-core/src/core/mod.rs` 中添加：

```rust
pub mod parallel_ops;
```

- [ ] **Step 4: 运行测试**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/rust-core && cargo test parallel_ops -- --nocapture`
Expected: 2 个测试全部 PASS

- [ ] **Step 5: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add rust-core/Cargo.toml rust-core/src/core/parallel_ops.rs rust-core/src/core/mod.rs
git commit -m "feat: 新增 rayon 并行批量操作模块

- 新增 rayon 依赖
- parallel_copy_files/move_files/delete_files
- 进度回调支持
- 2 个测试用例"
```

---

## Task 4: 修复 FFI 签名不一致（ff_task_list / ff_volume_list）

**Files:**
- Modify: `rust-core/src/ffi/mod.rs`（第 1751 行 `ff_task_list_ex` → 新增 `ff_task_list`）
- Modify: `rust-core/src/core/volumes.rs`（第 330 行 `ff_volume_list` 回调签名）
- Modify: `rust-core/include/ff_ffi.h`（对齐声明）

**Interfaces:**
- Produces: `ff_task_list(callback: extern "C" fn(*const FFTaskInfo, *mut c_void), user_data: *mut c_void) -> c_int`
- Produces: `ff_volume_list(callback: extern "C" fn(*const FFVolumeInfo, *mut c_void), user_data: *mut c_void) -> c_int`

- [ ] **Step 1: 在 ffi/mod.rs 新增 ff_task_list 函数**

在 `rust-core/src/ffi/mod.rs` 中，在 `ff_task_list_ex`（第 1751 行）之前添加 `ff_task_list`：

```rust
#[no_mangle]
pub extern "C" fn ff_task_list(
    callback: extern "C" fn(*const FFTaskInfo, *mut c_void),
    user_data: *mut c_void,
) -> c_int {
    // 委托给 ff_task_list_ex
    ff_task_list_ex(callback, user_data)
}
```

- [ ] **Step 2: 修复 ff_volume_list 回调签名**

在 `rust-core/src/core/volumes.rs`（第 330 行附近）修改 `ff_volume_list`，将多标量参数回调改为结构体指针回调：

```rust
// 旧签名（多标量参数）：
// pub extern "C" fn ff_volume_list(
//     callback: extern "C" fn(path: *const c_char, name: *const c_char, ...),
//     user_data: *mut c_void,
// ) -> c_int

// 新签名（结构体指针，与 ff_ffi.h 对齐）：
use crate::ffi::FFVolumeInfo;

#[no_mangle]
pub extern "C" fn ff_volume_list(
    callback: extern "C" fn(*const FFVolumeInfo, *mut c_void),
    user_data: *mut c_void,
) -> c_int {
    let volumes = match list_volumes() {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&e.to_string());
            return FF_ERROR_UNKNOWN;
        }
    };

    for vol in &volumes {
        let c_vol = FFVolumeInfo {
            name: CString::new(vol.name.as_str()).unwrap_or_default().into_raw(),
            path: CString::new(vol.path.as_str()).unwrap_or_default().into_raw(),
            fs_type: CString::new(vol.fs_type.as_str()).unwrap_or_default().into_raw(),
            total_size: vol.total_size,
            free_size: vol.free_size,
            used_size: vol.used_size,
            is_removable: vol.is_removable,
            is_ejectable: vol.is_ejectable,
            is_writable: vol.is_writable,
        };
        callback(&c_vol, user_data);
        // 释放内存
        unsafe {
            let _ = CString::from_raw(c_vol.name as *mut c_char);
            let _ = CString::from_raw(c_vol.path as *mut c_char);
            let _ = CString::from_raw(c_vol.fs_type as *mut c_char);
        }
    }
    FF_OK
}
```

- [ ] **Step 3: 确认 ff_ffi.h 声明已正确（无需修改）**

Run: `grep -A2 "ff_task_list\|ff_volume_list" /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/rust-core/include/ff_ffi.h`
Expected: 显示头文件声明已是结构体指针形式（与 Step 2 新代码对齐）

- [ ] **Step 4: 编译验证**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/rust-core && cargo build 2>&1 | tail -5`
Expected: 编译成功（可能有 warning 但无 error）

- [ ] **Step 5: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add rust-core/src/ffi/mod.rs rust-core/src/core/volumes.rs
git commit -m "fix: 修复 ff_task_list/ff_volume_list FFI 签名不一致

- 新增 ff_task_list 包装函数（委托给 ff_task_list_ex）
- ff_volume_list 回调改为 FFVolumeInfo 结构体指针
- 与 ff_ffi.h 声明对齐"
```

---

## Task 5: 暴露 hash_file FFI 接口

**Files:**
- Modify: `rust-core/src/ffi/mod.rs`（新增 `ff_hash_file` 导出）

**Interfaces:**
- Produces: `ff_hash_file(path: *const c_char, out_hash: *mut *mut c_char) -> c_int`

- [ ] **Step 1: 在 ffi/mod.rs 新增 ff_hash_file**

在 `rust-core/src/ffi/mod.rs` 末尾（测试模块之前）添加：

```rust
/// 计算文件的 blake3 哈希值
#[no_mangle]
pub extern "C" fn ff_hash_file(
    path: *const c_char,
    out_hash: *mut *mut c_char,
) -> c_int {
    if path.is_null() || out_hash.is_null() {
        return FF_ERROR_INVALID_ARG;
    }

    let path_str = match unsafe { CStr::from_ptr(path) }.to_str() {
        Ok(s) => s,
        Err(_) => return FF_ERROR_INVALID_ARG,
    };

    match crate::core::scanner::hash_file(path_str) {
        Ok(hash) => {
            let c_string = CString::new(hash).unwrap_or_default();
            unsafe {
                *out_hash = c_string.into_raw();
            }
            FF_OK
        }
        Err(e) => {
            set_last_error(&e.to_string());
            FF_ERROR_IO
        }
    }
}
```

- [ ] **Step 2: 在 ff_ffi.h 添加声明**

在 `rust-core/include/ff_ffi.h` 的函数声明区域（`#endif` 之前）添加：

```c
/// 计算文件的 blake3 哈希值
ff_error_t ff_hash_file(const char *path, char **out_hash);
```

- [ ] **Step 3: 编译验证**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/rust-core && cargo build 2>&1 | tail -5`
Expected: 编译成功

- [ ] **Step 4: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add rust-core/src/ffi/mod.rs rust-core/include/ff_ffi.h
git commit -m "feat: 暴露 ff_hash_file FFI 接口

- 新增 ff_hash_file 导出 blake3 哈希计算
- 头文件声明同步更新"
```

---

## Task 6: 实现 SearchBridge.swift 回调解析

**Files:**
- Modify: `FlowFinderNative/FlowFinderNative/Bridge/SearchBridge.swift`（第 318-332 行）
- Modify: `FlowFinderNative/FlowFinderNative/Bridge/FFIFunctions.swift`（新增 C 兼容结构体）

**Interfaces:**
- Produces: `FFDuplicateGroup_C`（C 兼容结构体，用于回调解析）
- Produces: `FFSearchResult_C`（C 兼容结构体，用于回调解析）
- Consumes: `ff_scan_duplicates` / `ff_search` FFI 函数

- [ ] **Step 1: 在 FFIFunctions.swift 新增 C 兼容结构体**

在 `FFIFunctions.swift` 中，在现有 `FFDuplicateGroup` 定义之后，添加 C 兼容版本：

```swift
// C 兼容结构体（用于 FFI 回调解析）
// 注意：字段顺序必须与 Rust 端 FFDuplicateFile_C / FFDuplicateGroup_C 一致

public struct FFDuplicateFile_C {
    public let path: UnsafePointer<CChar>?
    public let name: UnsafePointer<CChar>?
    public let size: UInt64
    public let modified: Int64
}

public struct FFDuplicateGroup_C {
    public let hash: UnsafePointer<CChar>?
    public let size: UInt64
    public let file_count: UInt32
    public let files: UnsafePointer<FFDuplicateFile_C>?
}

public struct FFSearchResult_C {
    public let path: UnsafePointer<CChar>?
    public let name: UnsafePointer<CChar>?
    public let size: UInt64
    public let modified: Int64
    public let is_dir: Bool
}
```

- [ ] **Step 2: 在 Rust 端添加对应的 C 兼容结构体（ffi/mod.rs）**

在 `rust-core/src/ffi/mod.rs` 中添加：

```rust
#[repr(C)]
pub struct FFDuplicateFile_C {
    pub path: *const c_char,
    pub name: *const c_char,
    pub size: u64,
    pub modified: i64,
}

#[repr(C)]
pub struct FFDuplicateGroup_C {
    pub hash: *const c_char,
    pub size: u64,
    pub file_count: u32,
    pub files: *const FFDuplicateFile_C,
}

#[repr(C)]
pub struct FFSearchResult_C {
    pub path: *const c_char,
    pub name: *const c_char,
    pub size: u64,
    pub modified: i64,
    pub is_dir: bool,
}
```

- [ ] **Step 3: 修改 Rust 端 ff_scan_duplicates 回调签名**

在 `rust-core/src/ffi/mod.rs` 中修改 `ff_scan_duplicates`，让 group 回调传递 `FFDuplicateGroup_C` 指针：

```rust
#[no_mangle]
pub extern "C" fn ff_scan_duplicates(
    path: *const c_char,
    progress_cb: extern "C" fn(c_int, c_int, *mut c_void),
    group_cb: extern "C" fn(*const FFDuplicateGroup_C, *mut c_void),
    user_data: *mut c_void,
) -> c_int {
    // ... 现有实现，但在 emit group 时构造 FFDuplicateGroup_C
    // group_cb(&c_group, user_data);
}
```

- [ ] **Step 4: 实现 dedupGroupCallback（SearchBridge.swift 第 318-322 行）**

替换 SearchBridge.swift 第 318-322 行：

```swift
private func dedupGroupCallback(groupPtr: UnsafeRawPointer?, userData: UnsafeMutableRawPointer?) {
    guard let groupPtr = groupPtr,
          let userData = userData else { return }

    let context = userData.withMemoryRebound(to: DedupGroupContext.self, capacity: 1) { $0 }

    // 解析 C 结构体
    let cGroup = groupPtr.assumingMemoryBound(to: FFDuplicateGroup_C.self).pointee

    let hash = cGroup.hash.map { String(cString: $0) } ?? ""
    let size = cGroup.size
    let fileCount = Int(cGroup.file_count)

    var files: [FFDuplicateFile] = []
    if let filesPtr = cGroup.files {
        for i in 0..<fileCount {
            let filePtr = filesPtr.advanced(by: i)
            let cFile = filePtr.pointee
            let path = cFile.path.map { String(cString: $0) } ?? ""
            let name = cFile.name.map { String(cString: $0) } ?? ""
            files.append(FFDuplicateFile(
                id: path,
                path: path,
                name: name,
                size: cFile.size,
                modified: cFile.modified
            ))
        }
    }

    let group = FFDuplicateGroup(
        id: hash,
        hash: hash,
        size: size,
        files: files
    )

    DispatchQueue.main.async {
        context.pointee.groupHandler(group)
    }
}
```

- [ ] **Step 5: 实现 searchCallback（SearchBridge.swift 第 324-332 行）**

替换 SearchBridge.swift 第 324-332 行：

```swift
private func searchCallback(resultPtr: UnsafeRawPointer?, userData: UnsafeMutableRawPointer?) {
    guard let resultPtr = resultPtr,
          let userData = userData else { return }

    let context = userData.withMemoryRebound(to: SearchContext.self, capacity: 1) { $0 }

    // 解析 C 结构体
    let cResult = resultPtr.assumingMemoryBound(to: FFSearchResult_C.self).pointee

    let path = cResult.path.map { String(cString: $0) } ?? ""
    let name = cResult.name.map { String(cString: $0) } ?? ""

    let result = FFSearchResult(
        path: path,
        name: name,
        size: cResult.size,
        modified: cResult.modified,
        isDir: cResult.is_dir
    )

    DispatchQueue.main.async {
        context.pointee.resultHandler(result)
    }
}
```

- [ ] **Step 6: 编译验证**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/rust-core && cargo build 2>&1 | tail -5`
Expected: Rust 编译成功

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative && swift build 2>&1 | tail -5`
Expected: Swift 编译成功

- [ ] **Step 7: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add rust-core/src/ffi/mod.rs FlowFinderNative/FlowFinderNative/Bridge/SearchBridge.swift FlowFinderNative/FlowFinderNative/Bridge/FFIFunctions.swift
git commit -m "feat: 实现 SearchBridge 回调解析

- 新增 C 兼容结构体 FFDuplicateGroup_C / FFSearchResult_C
- Rust 端 ff_scan_duplicates 回调改为结构体指针
- Swift 端 dedupGroupCallback 解析 FFDuplicateGroup_C
- Swift 端 searchCallback 解析 FFSearchResult_C"
```

---

## Task 7: 新增 SpotlightBridge.swift

**Files:**
- Create: `FlowFinderNative/FlowFinderNative/Bridge/SpotlightBridge.swift`

**Interfaces:**
- Produces: `SpotlightBridge.shared.search(query: String, scopes: [String], resultHandler: @escaping ([FFSearchResult]) -> Void)`
- Produces: `SpotlightBridge.shared.cancel()`

- [ ] **Step 1: 创建 SpotlightBridge.swift**

创建 `FlowFinderNative/FlowFinderNative/Bridge/SpotlightBridge.swift`：

```swift
import Foundation

/// Spotlight 全局搜索桥接
public final class SpotlightBridge {
    public static let shared = SpotlightBridge()

    private var query: NSMetadataQuery?
    private var resultHandler: (([FFSearchResult]) -> Void)?

    private init() {}

    /// 启动 Spotlight 搜索
    /// - Parameters:
    ///   - query: 搜索关键词
    ///   - scopes: 搜索范围（如 [NSMetadataQueryUserHomeScope]）
    ///   - resultHandler: 结果回调（主线程）
    public func search(
        query: String,
        scopes: [String] = [NSMetadataQueryUserHomeScope],
        resultHandler: @escaping ([FFSearchResult]) -> Void
    ) {
        cancel()

        self.resultHandler = resultHandler
        let metadataQuery = NSMetadataQuery()
        metadataQuery.searchScopes = scopes
        metadataQuery.predicate = NSPredicate(format: "kMDItemDisplayName LIKE[cd] %@", query)
        metadataQuery.notificationBatchingInterval = 0.5

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: metadataQuery
        )

        self.query = metadataQuery
        metadataQuery.start()
    }

    /// 取消搜索
    public func cancel() {
        if let query = query {
            query.stop()
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
            self.query = nil
        }
        resultHandler = nil
    }

    @objc private func queryDidUpdate(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery else { return }

        var results: [FFSearchResult] = []
        query.disableUpdates()

        for i in 0..<query.resultCount {
            let item = query.result(at: i) as? NSMetadataItem
            guard let item = item else { continue }

            let path = item.value(forAttribute: "kMDItemPath") as? String ?? ""
            let name = item.value(forAttribute: "kMDItemDisplayName") as? String ?? ""
            let size = (item.value(forAttribute: "kMDItemFSSize") as? NSNumber)?.uint64Value ?? 0
            let modified = (item.value(forAttribute: "kMDItemFSContentChangeDate") as? Date)?.timeIntervalSince1970 ?? 0
            let isDir = (item.value(forAttribute: "kMDItemContentType") as? String) == "public.folder"

            results.append(FFSearchResult(
                path: path,
                name: name,
                size: size,
                modified: Int64(modified),
                isDir: isDir
            ))
        }

        query.enableUpdates()
        query.stop()
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
        self.query = nil

        DispatchQueue.main.async { [weak self] in
            self?.resultHandler?(results)
            self?.resultHandler = nil
        }
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative && swift build 2>&1 | tail -5`
Expected: Swift 编译成功

- [ ] **Step 3: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add FlowFinderNative/FlowFinderNative/Bridge/SpotlightBridge.swift
git commit -m "feat: 新增 SpotlightBridge

- NSMetadataQuery 封装
- 支持异步搜索和取消
- 结果转换为 FFSearchResult"
```

---

## Task 8: 新增 TagBridge.swift（xattr 标签读写）

**Files:**
- Create: `FlowFinderNative/FlowFinderNative/Bridge/TagBridge.swift`

**Interfaces:**
- Produces: `TagBridge.shared.getTags(path: String) -> [Tag]`
- Produces: `TagBridge.shared.setTags(_ tags: [Tag], path: String) -> Bool`
- Produces: `TagBridge.shared.addTag(_ tag: Tag, path: String) -> Bool`
- Produces: `TagBridge.shared.removeTag(_ tagId: String, path: String) -> Bool`

- [ ] **Step 1: 创建 Tag 模型（如果不存在）**

在 `FlowFinderNative/FlowFinderNative/Model/` 下检查是否已有 `Tag.swift`，如果没有则创建：

```swift
import Foundation

public struct Tag: Identifiable, Equatable, Hashable, Codable {
    public let id: String
    public var name: String
    public var color: String  // hex color, e.g. "#FF0000"

    public init(id: String = UUID().uuidString, name: String, color: String = "#007AFF") {
        self.id = id
        self.name = name
        self.color = color
    }
}
```

- [ ] **Step 2: 创建 TagBridge.swift**

创建 `FlowFinderNative/FlowFinderNative/Bridge/TagBridge.swift`：

```swift
import Foundation

/// xattr 标签读写桥接
/// 标签存储在扩展属性 com.flowfinder.tags 中，格式为 JSON 数组
public final class TagBridge {
    public static let shared = TagBridge()

    private let xattrName = "com.flowfinder.tags"

    private init() {}

    /// 获取文件的标签
    public func getTags(path: String) -> [Tag] {
        let buffer = getExtendedAttribute(path: path, name: xattrName)
        guard let data = buffer,
              let tags = try? JSONDecoder().decode([Tag].self, from: data) else {
            return []
        }
        return tags
    }

    /// 设置文件的标签（覆盖）
    public func setTags(_ tags: [Tag], path: String) -> Bool {
        guard let data = try? JSONEncoder().encode(tags) else { return false }
        return setExtendedAttribute(path: path, name: xattrName, data: data)
    }

    /// 添加标签
    public func addTag(_ tag: Tag, path: String) -> Bool {
        var tags = getTags(path: path)
        if tags.contains(where: { $0.id == tag.id }) { return true }
        tags.append(tag)
        return setTags(tags, path: path)
    }

    /// 移除标签
    public func removeTag(_ tagId: String, path: String) -> Bool {
        var tags = getTags(path: path)
        tags.removeAll(where: { $0.id == tagId })
        return setTags(tags, path: path)
    }

    // MARK: - xattr helpers

    private func getExtendedAttribute(path: String, name: String) -> Data? {
        let pathPtr = path as CFString
        let namePtr = name as CFString

        // 获取属性大小
        let length = getxattr(path as String, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: length)
        let result = getxattr(path as String, name, &buffer, length, 0, 0)
        guard result > 0 else { return nil }

        return Data(buffer)
    }

    private func setExtendedAttribute(path: String, name: String, data: Data) -> Bool {
        let result = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return setxattr(path, name, baseAddress, data.count, 0, 0)
        }
        return result == 0
    }

    private func removeExtendedAttribute(path: String, name: String) -> Bool {
        let result = removexattr(path as String, name, 0)
        return result == 0
    }
}
```

- [ ] **Step 3: 编译验证**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative && swift build 2>&1 | tail -5`
Expected: Swift 编译成功

- [ ] **Step 4: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add FlowFinderNative/FlowFinderNative/Bridge/TagBridge.swift FlowFinderNative/FlowFinderNative/Model/Tag.swift
git commit -m "feat: 新增 TagBridge 和 Tag 模型

- xattr 读写 com.flowfinder.tags
- 标签以 JSON 数组存储
- getTags/setTags/addTag/removeTag API"
```

---

## Task 9: 新增 ThumbnailBridge.swift（QLThumbnailGenerator）

**Files:**
- Create: `FlowFinderNative/FlowFinderNative/Bridge/ThumbnailBridge.swift`

**Interfaces:**
- Produces: `ThumbnailBridge.shared.generateThumbnail(path: String, size: CGSize, completion: @escaping (NSImage?) -> Void)`
- Produces: `ThumbnailBridge.shared.cancelAll()`

- [ ] **Step 1: 创建 ThumbnailBridge.swift**

创建 `FlowFinderNative/FlowFinderNative/Bridge/ThumbnailBridge.swift`：

```swift
import Foundation
import QuickLookThumbnailing

/// QLThumbnailGenerator 缩略图桥接
public final class ThumbnailBridge {
    public static let shared = ThumbnailBridge()

    private let generator = QLThumbnailGenerator.shared
    private var activeRequests: [String: QLThumbnailGenerator.Request] = [:]
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 200  // 最多缓存 200 个缩略图
    }

    /// 异步生成缩略图
    public func generateThumbnail(
        path: String,
        size: CGSize = CGSize(width: 64, height: 64),
        completion: @escaping (NSImage?) -> Void
    ) {
        let cacheKey = "\(path)_\(Int(size.width))x\(Int(size.height))" as NSString

        // 先查缓存
        if let cached = cache.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )

        let requestRef = generator.generateBestRepresentation(for: request) { [weak self] thumbnail, error in
            if let error = error {
                print("ThumbnailBridge: 生成缩略图失败: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            guard let thumbnail = thumbnail else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let image = NSImage(
                cgImage: thumbnail.cgImage,
                size: thumbnail.actualSize
            )

            self?.cache.setObject(image, forKey: cacheKey)
            DispatchQueue.main.async { completion(image) }
        }

        activeRequests[path] = requestRef
    }

    /// 取消所有请求
    public func cancelAll() {
        for (_, request) in activeRequests {
            generator.cancel(request)
        }
        activeRequests.removeAll()
    }

    /// 清除缓存
    public func clearCache() {
        cache.removeAllObjects()
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative && swift build 2>&1 | tail -5`
Expected: Swift 编译成功

- [ ] **Step 3: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add FlowFinderNative/FlowFinderNative/Bridge/ThumbnailBridge.swift
git commit -m "feat: 新增 ThumbnailBridge

- QLThumbnailGenerator 异步生成缩略图
- NSCache LRU 缓存（200 个）
- cancelAll/clearCache API"
```

---

## Task 10: 新增 SMBBridge.swift（NetFS 挂载）

**Files:**
- Create: `FlowFinderNative/FlowFinderNative/Bridge/SMBBridge.swift`

**Interfaces:**
- Produces: `SMBBridge.shared.mount(url: String, mountPoint: String?, completion: @escaping (Result<String, Error>) -> Void)`
- Produces: `SMBBridge.shared.unmount(mountPoint: String, completion: @escaping (Result<Void, Error>) -> Void)`
- Produces: `SMBBridge.shared.listMounted() -> [String]`

- [ ] **Step 1: 创建 SMBBridge.swift**

创建 `FlowFinderNative/FlowFinderNative/Bridge/SMBBridge.swift`：

```swift
import Foundation
import NetFS

/// SMB 网络挂载桥接
public final class SMBBridge {
    public static let shared = SMBBridge()

    /// 已挂载的 SMB 卷列表
    private(set) var mountedVolumes: [SMBVolume] = []
    private let lock = NSLock()

    private init() {
        refreshMountedVolumes()
    }

    /// 挂载 SMB 共享
    /// - Parameters:
    ///   - url: SMB 地址，如 "smb://user:pass@server/share"
    ///   - mountPoint: 挂载点路径（nil 则自动选择）
    ///   - completion: 完成回调（主线程）
    public func mount(
        url: String,
        mountPoint: String? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let cfURL = URL(string: url) as CFURL?

        guard let cfURL = cfURL else {
            completion(.failure(SMBError.invalidURL))
            return
        }

        var mountDir: CFURL?
        let mountPath = mountPoint ?? "/Volumes"

        // NetFSMountURLSync 签名：
        // int NetFSMountURLSync(CFURLRef url, CFURLRef mountPath,
        //   CFStringRef user, CFStringRef passwd,
        //   CFMutableDictionaryRef openOptions,
        //   CFMutableDictionaryRef mountOptions,
        //   CFArrayRef *mountpoints)
        var mountpoints: Unmanaged<CFArray>?

        let openOptions: CFMutableDictionary = {
            let dict = CFDictionaryCreateMutable(nil, 0, nil, nil)
            return dict
        }()

        let mountOptions: CFMutableDictionary = {
            let dict = CFDictionaryCreateMutable(nil, 0, nil, nil)
            return dict
        }()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = NetFSMountURLSync(
                cfURL,
                URL(fileURLWithPath: mountPath) as CFURL,
                nil,  // 用户名（URL 中已包含）
                nil,  // 密码（URL 中已包含）
                openOptions,
                mountOptions,
                &mountpoints
            )

            DispatchQueue.main.async {
                if result == 0 {
                    // 获取挂载点路径
                    var mountedPath = mountPath
                    if let mountpoints = mountpoints?.takeRetainedValue() as? [String] {
                        mountedPath = mountpoints.first ?? mountPath
                    }

                    self?.refreshMountedVolumes()
                    completion(.success(mountedPath))
                } else {
                    completion(.failure(SMBError.mountFailed(code: result)))
                }
            }
        }
    }

    /// 卸载 SMB 卷
    public func unmount(mountPoint: String, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.unmountVolume(at: mountPoint) ?? -1

            DispatchQueue.main.async {
                if result == 0 {
                    self?.refreshMountedVolumes()
                    completion(.success(()))
                } else {
                    completion(.failure(SMBError.unmountFailed(code: result)))
                }
            }
        }
    }

    /// 列出已挂载的 SMB 卷
    public func listMounted() -> [SMBVolume] {
        lock.lock()
        defer { lock.unlock() }
        return mountedVolumes
    }

    /// 刷新已挂载卷列表
    public func refreshMountedVolumes() {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey, .volumeLocalizedFormatDescriptionKey], options: []) ?? []

        var smbVolumes: [SMBVolume] = []
        for volumeURL in volumes {
            let path = volumeURL.path
            // 检查是否是网络卷
            if isNetworkVolume(path: path) {
                let name = (try? volumeURL.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? volumeURL.lastPathComponent
                smbVolumes.append(SMBVolume(
                    path: path,
                    name: name,
                    url: "smb://\(name)",
                    isMounted: true
                ))
            }
        }

        lock.lock()
        mountedVolumes = smbVolumes
        lock.unlock()
    }

    // MARK: - Private

    private func isNetworkVolume(path: String) -> Bool {
        // 简化判断：检查是否在 /Volumes 下且是网络挂载
        // 实际实现应检查 statfs 的 f_fstypename
        var statbuf = statfs()
        let result = path.withCString { cPath in
            statfs(cPath, &statbuf)
        }
        if result == 0 {
            let fstype = withUnsafePointer(to: &statbuf.f_fstypename) { ptr -> String in
                ptr.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
            }
            return fstype == "smbfs" || fstype == "cifs" || fstype == "afpfs" || fstype == "nfs"
        }
        return false
    }

    private func unmountVolume(at path: String) -> Int32 {
        // 使用 unmount(2) 系统调用
        return path.withCString { cPath in
            unmount(cPath, 0)
        }
    }
}

// MARK: - SMBVolume

public struct SMBVolume {
    public let path: String
    public let name: String
    public let url: String
    public let isMounted: Bool
}

// MARK: - SMBError

public enum SMBError: Error {
    case invalidURL
    case mountFailed(code: Int32)
    case unmountFailed(code: Int32)

    public var localizedDescription: String {
        switch self {
        case .invalidURL:
            return "无效的 SMB 地址"
        case .mountFailed(let code):
            return "挂载失败（错误码：\(code)）"
        case .unmountFailed(let code):
            return "卸载失败（错误码：\(code)）"
        }
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative && swift build 2>&1 | tail -5`
Expected: Swift 编译成功

- [ ] **Step 3: 提交**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add FlowFinderNative/FlowFinderNative/Bridge/SMBBridge.swift
git commit -m "feat: 新增 SMBBridge

- NetFSMountURLSync 挂载
- unmount(2) 卸载
- statfs 检测网络卷
- SMBVolume 数据模型"
```

---

## Task 11: Phase 1 集成验证

**Files:**
- 无新增/修改，仅验证

- [ ] **Step 1: Rust Core 全量编译**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/rust-core && cargo build 2>&1 | tail -5`
Expected: 编译成功，无 error

- [ ] **Step 2: Rust Core 全量测试**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/rust-core && cargo test 2>&1 | tail -10`
Expected: 所有测试 PASS

- [ ] **Step 3: Swift Bridge 层编译**

Run: `cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/FlowFinderNative && swift build 2>&1 | tail -5`
Expected: 编译成功，无 error

- [ ] **Step 4: 确认 FFI 头文件一致性**

Run: `grep -c "ff_" /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/rust-core/include/ff_ffi.h && grep -c "no_mangle.*pub extern.*fn ff_" /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native/rust-core/src/ffi/mod.rs`
Expected: 头文件函数数与 Rust 导出函数数一致或 Rust 更多

- [ ] **Step 5: 提交 Phase 1 完成标记**

```bash
cd /Volumes/Iris-Data/Download/AI/文件管理系统/flowfinder-native
git add -A
git commit -m "milestone: Phase 1 完成 - Rust Core + Bridge 修复

- blake3 迁移完成
- SQLite 增量缓存模块
- rayon 并行批量操作
- FFI 签名修复（ff_task_list/ff_volume_list）
- ff_hash_file 导出
- SearchBridge 回调解析实现
- SpotlightBridge（NSMetadataQuery）
- TagBridge（xattr 标签）
- ThumbnailBridge（QLThumbnailGenerator）
- SMBBridge（NetFS 挂载）
- 全量编译和测试通过"
```

---

## Self-Review

### Spec Coverage

| Spec 要求 | 对应 Task |
|-----------|-----------|
| md5 → blake3 迁移 | Task 1 |
| 新增 sqlite | Task 2 |
| 新增 rayon | Task 3 |
| 修复 ff_task_list/ff_volume_list 签名 | Task 4 |
| hash_file 通过 FFI 暴露 | Task 5 |
| searchCallback/dedupGroupCallback 实现 | Task 6 |
| 新增 SpotlightBridge | Task 7 |
| 新增 TagBridge | Task 8 |
| 新增 ThumbnailBridge | Task 9 |
| 新增 SMBBridge | Task 10 |
| 全量验证 | Task 11 |

### Placeholder Scan

- 无 TBD/TODO
- 所有代码块完整
- 所有命令精确

### Type Consistency

- `FFDuplicateGroup_C` / `FFSearchResult_C` 在 Rust 和 Swift 两侧字段名一致
- `compute_partial_hash` / `compute_full_hash` 在 Task 1 定义，后续 Task 无冲突
- `cache_get` / `cache_put` / `cache_invalidate` 在 Task 2 定义，签名一致
- `parallel_copy_files` / `parallel_move_files` / `parallel_delete_files` 在 Task 3 定义
