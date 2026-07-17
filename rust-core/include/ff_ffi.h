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
    FF_ERROR = -1,
    FF_INVALID_PATH = -2,
    FF_IO_ERROR = -3,
    FF_NOT_FOUND = -4,
    FF_DUPLICATE = -5,
    FF_PERMISSION_DENIED = -6,
} ff_error_t;

/* ── Handle types ───────────────────────────────────────────── */
typedef struct ff_scanner *ff_scanner_t;
typedef struct ff_dedup_engine *ff_dedup_engine_t;
typedef struct ff_dir_cache *ff_dir_cache_t;

/* ── Callback types ─────────────────────────────────────────── */
typedef void (*ff_progress_cb)(const char *path, uint64_t current, uint64_t total, void *user_data);
typedef void (*ff_result_cb)(const char *path, void *user_data);

/* ── Scanner API ────────────────────────────────────────────── */
ff_scanner_t ff_scanner_new(void);
void ff_scanner_free(ff_scanner_t scanner);
ff_error_t ff_scanner_add_path(ff_scanner_t scanner, const char *path);
ff_error_t ff_scanner_run(ff_scanner_t scanner, ff_progress_cb progress, ff_result_cb result, void *user_data);
uint64_t ff_scanner_file_count(ff_scanner_t scanner);

/* ── Dedup Engine API ───────────────────────────────────────── */
ff_dedup_engine_t ff_dedup_engine_new(void);
void ff_dedup_engine_free(ff_dedup_engine_t engine);
ff_error_t ff_dedup_engine_add_file(ff_dedup_engine_t engine, const char *path, uint64_t size);
ff_error_t ff_dedup_engine_run(ff_dedup_engine_t engine, ff_progress_cb progress, void *user_data);
uint64_t ff_dedup_engine_duplicate_count(ff_dedup_engine_t engine);
uint64_t ff_dedup_engine_wasted_bytes(ff_dedup_engine_t engine);

/* ── Dir Cache API ──────────────────────────────────────────── */
ff_dir_cache_t ff_dir_cache_new(const char *root_path);
void ff_dir_cache_free(ff_dir_cache_t cache);
ff_error_t ff_dir_cache_refresh(ff_dir_cache_t cache);
ff_error_t ff_dir_cache_get_children(ff_dir_cache_t cache, const char *path, char ***out_children, size_t *out_count);
void ff_dir_cache_free_children(char **children, size_t count);

/* ── CoW Copy API ───────────────────────────────────────────── */
ff_error_t ff_cow_copy(const char *src, const char *dst);
bool ff_cow_supported(const char *path);

/* ── Bulk Read API ──────────────────────────────────────────── */
ff_error_t ff_bulk_read(const char **paths, size_t count, uint8_t ***out_buffers, size_t **out_sizes);
void ff_bulk_read_free(uint8_t **buffers, size_t *sizes, size_t count);

/* ── Path Guard API ─────────────────────────────────────────── */
ff_error_t ff_path_guard_lock(const char *path);
void ff_path_guard_unlock(const char *path);
bool ff_path_guard_is_locked(const char *path);

/* ── Utility API ────────────────────────────────────────────── */
char *ff_version_string(void);
void ff_free_string(char *s);
uint64_t ff_get_system_memory(void);

#ifdef __cplusplus
}
#endif

#endif /* FF_FFI_H */
