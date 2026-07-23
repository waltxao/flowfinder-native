//! Duplicate-file detection engine.
//!
//! Uses a three-phase strategy to find byte-for-byte identical files
//! efficiently:
//!
//! 1. **Size grouping** — walk every regular file and group by size. Only
//!    groups with more than one file can possibly contain duplicates, so
//!    unique-size files are discarded immediately (no hashing at all).
//! 2. **Partial hash** — for each size group, compute a blake3 digest of the
//!    first 4 KB + last 4 KB (or the entire file when smaller than 8 KB).
//!    This eliminates most non-duplicates with minimal I/O.
//! 3. **Full hash** — for files that agree on the partial hash, compute a
//!    full blake3 digest to confirm they are truly identical.
//!
//! Progress and discovered groups are streamed to the frontend through a
//! Tauri [`Channel`]. Confirmed duplicate groups are emitted as
//! [`DedupEvent::GroupFound`] *immediately* when they are confirmed, rather
//! than waiting for the entire scan to finish.

use std::collections::HashMap;
use std::path::Path as StdPath;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use walkdir::WalkDir;

/// 抽象事件发射器，解耦 core 层与上层 IPC。
///
/// core 层通过此 trait 发送事件，不直接依赖任何特定 IPC 机制。
/// 任何实现此 trait 的类型（如 FFI 回调、测试 mock、日志收集器）都可以
/// 作为事件接收方。
pub trait EventEmitter {
    fn emit(&self, event: DedupEvent);
}

/// Size of each partial-hash chunk (4 KB).
const PARTIAL_CHUNK: usize = 4096;
/// Files smaller than this are hashed in full during phase 2.
const SMALL_FILE_THRESHOLD: u64 = 8192;

/// One physical file inside a duplicate group.
#[derive(Debug, Clone)]
pub struct DuplicateFile {
    pub id: String,
    pub path: String,
    pub name: String,
    pub size: u64,
    pub modified: i64,
}

/// A set of files that are byte-for-byte identical.
#[derive(Debug, Clone)]
pub struct DuplicateGroup {
    pub id: String,
    pub hash: String,
    pub size: u64,
    pub files: Vec<DuplicateFile>,
}

/// Events streamed from [`run_scan`].
#[derive(Debug, Clone)]
pub enum DedupEvent {
    Progress {
        scanned: usize,
        total: Option<usize>,
    },
    GroupFound {
        group: DuplicateGroup,
    },
    Done {
        groups: usize,
    },
    Error {
        message: String,
    },
}

/// Convert a blake3 hash into a lowercase hex string.
fn blake3_to_hex(hash: blake3::Hash) -> String {
    hash.to_hex().to_string()
}

/// Compute a partial blake3 hash of `path`.
///
/// For files smaller than 8 KB the entire content is hashed. For larger
/// files the first 4 KB and the last 4 KB are hashed (head + tail). This is
/// enough to eliminate the vast majority of non-duplicates cheaply.
fn partial_hash(path: &str, size: u64) -> std::io::Result<String> {
    use std::io::{Read, Seek, SeekFrom};

    let mut file = std::fs::File::open(path)?;
    let mut hasher = blake3::Hasher::new();

    if size < SMALL_FILE_THRESHOLD {
        // Small file — hash everything.
        let mut buf = [0u8; SMALL_FILE_THRESHOLD as usize];
        loop {
            let n = file.read(&mut buf)?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
        }
    } else {
        // Hash the first 4 KB …
        let mut head = [0u8; PARTIAL_CHUNK];
        let n = file.read(&mut head)?;
        hasher.update(&head[..n]);

        // … and the last 4 KB.
        file.seek(SeekFrom::End(-(PARTIAL_CHUNK as i64)))?;
        let mut tail = [0u8; PARTIAL_CHUNK];
        let n = file.read(&mut tail)?;
        hasher.update(&tail[..n]);
    }

    Ok(blake3_to_hex(hasher.finalize()))
}

/// Compute a full blake3 hash of `path`.
fn full_hash(path: &str) -> std::io::Result<String> {
    use std::io::Read;

    let mut file = std::fs::File::open(path)?;
    let mut hasher = blake3::Hasher::new();
    let mut buf = [0u8; 65_536];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(blake3_to_hex(hasher.finalize()))
}

/// Build a [`DuplicateFile`] from a filesystem path.
fn build_file(path: &str, size: u64) -> DuplicateFile {
    let name = StdPath::new(path)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    let modified = std::fs::metadata(path)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    DuplicateFile {
        id: path.to_string(),
        path: path.to_string(),
        name,
        size,
        modified,
    }
}

/// Run a full deduplication scan across `paths` using the three-phase
/// strategy.
///
/// Returns every [`DuplicateGroup`] containing more than one file. The same
/// groups are also streamed one by one through `on_event` as they are
/// confirmed (during phase 3), followed by a final [`DedupEvent::Done`].
///
/// `cancel_token` is polled periodically; when it is set to `true` the scan
/// stops at the next check point and returns whatever groups have been
/// confirmed so far. This lets the frontend cancel a long-running scan
/// without leaving the background task spinning.
pub fn run_scan(
    paths: Vec<String>,
    on_event: &impl EventEmitter,
    cancel_token: Arc<AtomicBool>,
) -> Vec<DuplicateGroup> {
    let is_cancelled = || cancel_token.load(Ordering::Relaxed);

    // ------------------------------------------------------------------
    // Collect every regular file first so we can report a stable total.
    // ------------------------------------------------------------------
    let mut files: Vec<(String, u64)> = Vec::new();
    'collect: for root in &paths {
        for entry in WalkDir::new(root).into_iter().filter_map(|e| e.ok()) {
            if is_cancelled() {
                break 'collect;
            }
            if entry.file_type().is_file() {
                if let Ok(meta) = entry.metadata() {
                    files.push((entry.path().to_string_lossy().to_string(), meta.len()));
                }
            }
        }
    }

    // If the user cancelled during collection, emit a final Done and return
    // the (empty) set of groups found so far.
    if is_cancelled() {
        let _ = on_event.emit(DedupEvent::Progress {
            scanned: 0,
            total: Some(files.len()),
        });
        let _ = on_event.emit(DedupEvent::Done { groups: 0 });
        return Vec::new();
    }

    let total = files.len();
    let _ = on_event.emit(DedupEvent::Progress {
        scanned: 0,
        total: Some(total),
    });

    // ------------------------------------------------------------------
    // Phase 1 — group by size (fast, metadata only — no file I/O).
    // ------------------------------------------------------------------
    let mut by_size: HashMap<u64, Vec<(String, u64)>> = HashMap::new();
    for (path, size) in files {
        by_size.entry(size).or_default().push((path, size));
    }

    // Only groups with more than one file can contain duplicates.
    let size_groups: Vec<Vec<(String, u64)>> =
        by_size.into_values().filter(|v| v.len() > 1).collect();

    let mut scanned = 0usize;
    let mut all_groups: Vec<DuplicateGroup> = Vec::new();

    for size_group in &size_groups {
        // Honour a cancel request between size groups.
        if is_cancelled() {
            break;
        }

        // --------------------------------------------------------------
        // Phase 2 — partial hash (first 4 KB + last 4 KB, or full for
        // files < 8 KB).  blake3 keeps this cheap.
        // --------------------------------------------------------------
        let mut by_partial: HashMap<String, Vec<(String, u64)>> = HashMap::new();
        for (path, size) in size_group {
            if is_cancelled() {
                break;
            }
            scanned += 1;
            match partial_hash(path, *size) {
                Ok(h) => {
                    by_partial.entry(h).or_default().push((path.clone(), *size));
                }
                Err(e) => {
                    let _ = on_event.emit(DedupEvent::Error {
                        message: format!("{}: {}", path, e),
                    });
                }
            }
            if scanned % 25 == 0 || scanned >= total {
                let _ = on_event.emit(DedupEvent::Progress {
                    scanned,
                    total: Some(total),
                });
            }
        }

        // --------------------------------------------------------------
        // Phase 3 — full blake3 hash to confirm true duplicates.
        // --------------------------------------------------------------
        for partial_members in by_partial.into_values() {
            if partial_members.len() < 2 {
                continue;
            }
            if is_cancelled() {
                break;
            }
            let mut by_full: HashMap<String, Vec<(String, u64)>> = HashMap::new();
            for (path, size) in partial_members {
                match full_hash(&path) {
                    Ok(h) => {
                        by_full.entry(h).or_default().push((path.clone(), size));
                    }
                    Err(e) => {
                        let _ = on_event.emit(DedupEvent::Error {
                            message: format!("{}: {}", path, e),
                        });
                    }
                }
            }

            // Emit each confirmed group immediately.
            for (hash, mut members) in by_full.into_iter() {
                if members.len() < 2 {
                    continue;
                }
                let size = members.first().map(|(_, s)| *s).unwrap_or(0);
                members.sort_by(|a, b| a.0.cmp(&b.0));
                let group = DuplicateGroup {
                    id: hash.clone(),
                    hash,
                    size,
                    files: members
                        .into_iter()
                        .map(|(path, size)| build_file(&path, size))
                        .collect(),
                };
                // Emit immediately — do not wait for the full scan to finish.
                let _ = on_event.emit(DedupEvent::GroupFound {
                    group: group.clone(),
                });
                all_groups.push(group);
            }
        }
    }

    // Final progress + done.
    let _ = on_event.emit(DedupEvent::Progress {
        scanned: total,
        total: Some(total),
    });

    // Largest groups first for a sensible UI default ordering.
    all_groups.sort_by(|a, b| b.size.cmp(&a.size));

    let _ = on_event.emit(DedupEvent::Done {
        groups: all_groups.len(),
    });

    all_groups
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// Mock EventEmitter that collects all emitted events into a Vec.
    /// Wrapped in Mutex so it can be shared across the scan closure.
    struct MockEmitter {
        events: Mutex<Vec<DedupEvent>>,
    }

    impl MockEmitter {
        fn new() -> Self {
            Self {
                events: Mutex::new(Vec::new()),
            }
        }

        fn events(&self) -> Vec<DedupEvent> {
            self.events.lock().unwrap().clone()
        }
    }

    impl EventEmitter for MockEmitter {
        fn emit(&self, event: DedupEvent) {
            self.events.lock().unwrap().push(event);
        }
    }

    #[test]
    fn run_scan_empty_dir_emits_done() {
        let dir = std::env::temp_dir();
        let emitter = MockEmitter::new();
        let cancel = Arc::new(AtomicBool::new(false));

        let groups = run_scan(
            vec![dir.to_string_lossy().to_string()],
            &emitter,
            cancel,
        );

        // An empty-ish temp dir may still contain files, but the scan must
        // always emit at least one Progress and one Done event.
        let events = emitter.events();
        assert!(
            events.iter().any(|e| matches!(e, DedupEvent::Done { .. })),
            "expected at least one Done event"
        );
        // groups should be a Vec (possibly empty).
        let _ = groups;
    }

    #[test]
    fn run_scan_respects_cancel_token() {
        let dir = std::env::temp_dir();
        let emitter = MockEmitter::new();
        // Pre-set the cancel flag so the scan bails out during collection.
        let cancel = Arc::new(AtomicBool::new(true));

        let groups = run_scan(
            vec![dir.to_string_lossy().to_string()],
            &emitter,
            cancel,
        );

        // When cancelled during collection, the scan returns an empty Vec
        // and still emits a Done event.
        assert!(groups.is_empty(), "cancelled scan should return no groups");
        let events = emitter.events();
        assert!(
            events.iter().any(|e| matches!(e, DedupEvent::Done { groups: 0 })),
            "expected Done with 0 groups on cancel"
        );
    }

    #[test]
    fn test_partial_hash_small_file() {
        let dir = std::env::temp_dir();
        let path = dir.join("test_small_blake3.txt");
        std::fs::write(&path, b"hello world").unwrap();
        let hash = partial_hash(path.to_str().unwrap(), 11).unwrap();
        assert!(!hash.is_empty());
        assert_eq!(hash.len(), 64); // blake3 hex = 32 bytes = 64 chars
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_full_hash_large_file() {
        use std::io::Write;
        let dir = std::env::temp_dir();
        let path = dir.join("test_large_blake3.bin");
        let mut file = std::fs::File::create(&path).unwrap();
        let data = vec![0xABu8; 16384];
        file.write_all(&data).unwrap();
        drop(file);
        let hash = full_hash(path.to_str().unwrap()).unwrap();
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
        let hash1 = full_hash(path1.to_str().unwrap()).unwrap();
        let hash2 = full_hash(path2.to_str().unwrap()).unwrap();
        assert_eq!(hash1, hash2);
        std::fs::remove_file(&path1).ok();
        std::fs::remove_file(&path2).ok();
    }
}
