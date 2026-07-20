#ifndef FF_FFI_H
#define FF_FFI_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Error codes ────────────────────────────────────────────── */
typedef enum {
    FF_OK = 0,
    FF_ERR_GENERIC = -1,
    FF_ERR_INVALID_PATH = -2,
    FF_ERR_IO = -3,
    FF_ERR_NOT_FOUND = -4,
    FF_ERR_DUPLICATE = -5,
    FF_ERR_PERMISSION_DENIED = -6,
} ff_error_t;

/* ── Directory entry (C-compatible) ─────────────────────────── */
typedef struct {
    char *name;
    char *path;
    char *extension;
    bool is_dir;
    bool is_file;
    bool is_symlink;
    bool is_hidden;
    bool is_system_protected;
    uint64_t size;
    int64_t modified;
    int64_t created;
} FFEntryRef;

/* ── Duplicate file info ─────────────────────────────────── */
typedef struct {
    char *id;
    char *path;
    char *name;
    uint64_t size;
    int64_t modified;
} FFDuplicateFile;

/* ── Duplicate group info ──────────────────────────────────── */
typedef struct {
    char *id;
    char *hash;
    uint64_t size;
    FFDuplicateFile *files;
    size_t file_count;
} FFDuplicateGroup;

/* ── Search result ───────────────────────────────────────── */
typedef struct {
    char *path;
    char *name;
    uint64_t size;
    int64_t modified;
    bool is_dir;
} FFSearchResult;

/* ── Search filters ──────────────────────────────────────── */
typedef struct {
    const char *file_types;
    uint64_t min_size;
    uint64_t max_size;
    int64_t modified_after;
    int64_t modified_before;
    bool has_file_types;
    bool has_min_size;
    bool has_max_size;
    bool has_modified_after;
    bool has_modified_before;
} FFSearchFilters;

/* ── Callback types ───────────────────────────────────────── */
typedef void (*FFEntryCallback)(const FFEntryRef *entry, void *user_data);
typedef void (*FFDedupProgressCallback)(size_t scanned, size_t total, void *user_data);
typedef void (*FFDedupGroupCallback)(const FFDuplicateGroup *group, void *user_data);
typedef void (*FFSearchCallback)(const FFSearchResult *result, void *user_data);

/* ── Directory listing API ──────────────────────────────────── */
ff_error_t ff_list_dir(const char *path, FFEntryCallback callback, void *user_data);

/* ── File operations API ───────────────────────────────────── */
ff_error_t ff_copy_file(const char *src, const char *dst);
ff_error_t ff_move_file(const char *src, const char *dst);
ff_error_t ff_delete_file(const char *path);
ff_error_t ff_delete_dir(const char *path);
ff_error_t ff_create_dir(const char *path);
ff_error_t ff_rename(const char *src, const char *dst);

/* ── Duplicate file detection API ─────────────────────────── */
ff_error_t ff_scan_duplicates(const char *path,
                              FFDedupProgressCallback progress_callback,
                              FFDedupGroupCallback group_callback,
                              void *user_data);
void ff_cancel_scan(void);

/* ── File search API ───────────────────────────────────────── */
ff_error_t ff_search(const char *path, const char *query,
                       FFSearchCallback callback, void *user_data);
ff_error_t ff_search_with_filters(const char *path, const char *query,
                                   const FFSearchFilters *filters,
                                   FFSearchCallback callback, void *user_data);

/* ── QuickLook preview API ─────────────────────────────────── */
ff_error_t ff_get_preview_path(const char *path,
                                void (*callback)(const char *preview_path, void *user_data),
                                void *user_data);
char *ff_get_file_type(const char *path);

/* ── Directory Cache API ───────────────────────────────────── */
ff_error_t ff_cache_invalidate(const char *path);
ff_error_t ff_cache_get(const char *path, FFEntryCallback callback, void *user_data);
ff_error_t ff_cache_put(const char *path, const FFEntryRef *entries, size_t entry_count);

/* ── Directory Cache API (Sub-project 5) ───────────────────── */
ff_error_t ff_dir_cache_get(const char *path, FFEntryCallback callback, void *user_data);
ff_error_t ff_dir_cache_invalidate(const char *path);
ff_error_t ff_dir_cache_clear(void);

/* ── FSEvents Watcher API (Sub-project 5) ──────────────────── */
typedef void (*FSEventCallback)(const char *path, void *user_data);
ff_error_t ff_fsevents_start(const char *path, FSEventCallback callback, void *user_data);
ff_error_t ff_fsevents_stop(int32_t handle);

/* ── Batch Rename & Organize API (Sub-project 6) ─────────── */
typedef struct {
    char *original_path;
    char *new_name;
} FFRenameItem;

ff_error_t ff_batch_rename(const FFRenameItem *items, size_t item_count);
ff_error_t ff_organize_by_date(const char *path, const char *format);
ff_error_t ff_organize_by_type(const char *path);

/* ── Thumbnail Generation API (Sub-project 7) ─────────────── */
ff_error_t ff_generate_thumbnail(const char *path, uint32_t max_size,
                                   void (*callback)(const char *thumbnail_path, void *user_data),
                                   void *user_data);
ff_error_t ff_generate_thumbnails(const char **paths, size_t path_count, uint32_t max_size,
                                   void (*callback)(const char *thumbnail_path, void *user_data),
                                   void *user_data);

/* ── Error handling API ─────────────────────────────────────── */
char *ff_last_error(void);
void ff_free_string(char *s);

/* ── Settings & Configuration API (Sub-project 8) ─────────── */
char *ff_settings_load(void);
ff_error_t ff_settings_save(const char *json);
char *ff_settings_get(const char *key);
ff_error_t ff_settings_set(const char *key, const char *value);

/* ── Task Scheduler API (Sub-project 9) ───────────────────── */
typedef enum {
    FF_TASK_PRIORITY_LOW = 0,
    FF_TASK_PRIORITY_NORMAL = 1,
    FF_TASK_PRIORITY_HIGH = 2,
} ff_task_priority_t;

typedef enum {
    FF_TASK_STATUS_PENDING = 0,
    FF_TASK_STATUS_RUNNING = 1,
    FF_TASK_STATUS_COMPLETED = 2,
    FF_TASK_STATUS_FAILED = 3,
    FF_TASK_STATUS_CANCELLED = 4,
} ff_task_status_t;

typedef struct {
    char *id;
    char *name;
    char *description;
    ff_task_priority_t priority;
    ff_task_status_t status;
    double progress;
    int64_t created_at;
    int64_t started_at;
    int64_t completed_at;
} FFTaskInfo;

ff_error_t ff_task_submit(const char *name, const char *description,
                          ff_task_priority_t priority, char **out_task_id);
ff_error_t ff_task_cancel(const char *task_id);
ff_error_t ff_task_list(void (*callback)(const FFTaskInfo *task, void *user_data),
                        void *user_data);
ff_error_t ff_task_progress(const char *task_id, double *out_progress);

/* ── Volume Management API (Sub-project 10) ──────────────── */
typedef struct {
    char *name;
    char *path;
    char *fs_type;
    uint64_t total_size;
    uint64_t free_size;
    uint64_t used_size;
    bool is_removable;
    bool is_ejectable;
    bool is_writable;
} FFVolumeInfo;

ff_error_t ff_volume_list(void (*callback)(const FFVolumeInfo *volume, void *user_data),
                          void *user_data);
ff_error_t ff_volume_info(const char *path, FFVolumeInfo *out_info);
ff_error_t ff_volume_health_check(const char *path, char **out_result);
ff_error_t ff_volume_eject(const char *path);
ff_error_t ff_volume_mount(const char *path, const char *options);

/* ── Utility API ────────────────────────────────────────────── */
char *ff_version_string(void);
uint64_t ff_get_system_memory(void);

/* ── Hashing API ───────────────────────────────────────────── */
ff_error_t ff_hash_file(const char *path, char **out_hash);

#ifdef __cplusplus
}
#endif

#endif /* FF_FFI_H */
