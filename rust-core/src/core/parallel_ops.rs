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

    crate::core::cow_copy::copy_file_cow(src_path, &dst_path).map(|_| ())
}

fn move_single(src: &str, dst_dir: &str) -> io::Result<()> {
    let src_path = Path::new(src);
    let file_name = src_path.file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "无法获取文件名"))?;
    let dst_path = Path::new(dst_dir).join(file_name);

    std::fs::rename(src, &dst_path)
        .or_else(|_| {
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
