use rusqlite::{params, Connection};
use std::io;
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
        let path: String = row.get(0)?;
        let name: String = row.get(1)?;
        Ok(FileEntrySkeleton {
            id: format!("{}:{}", name, path),
            path,
            name,
            is_dir: row.get::<_, i32>(2)? != 0,
            is_file: row.get::<_, i32>(3)? != 0,
            is_symlink: row.get::<_, i32>(4)? != 0,
            is_hidden: row.get::<_, i32>(5)? != 0,
            extension: row.get(6)?,
            size: row.get::<_, i64>(7)? as u64,
            modified: row.get(8)?,
            created: row.get(9)?,
            is_system_protected: row.get::<_, i32>(10)? != 0,
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
