#define _GNU_SOURCE
#include <dlfcn.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef O_TMPFILE
#define O_TMPFILE 020200000
#endif

extern char **environ;

static int (*real_access)(const char *, int) = NULL;
static int sys_access_fallback(const char *path, int mode) {
#ifdef SYS_faccessat
    return (int)syscall(SYS_faccessat, AT_FDCWD, path, mode);
#elif defined(SYS_access)
    return (int)syscall(SYS_access, path, mode);
#else
    (void)path;
    (void)mode;
    errno = ENOSYS;
    return -1;
#endif
}

static const char *safe_getenv(const char *name) {
    if (!name || !environ) return NULL;
    size_t nlen = strlen(name);
    for (char **ep = environ; *ep != NULL; ep++) {
        const char *entry = *ep;
        if (strncmp(entry, name, nlen) == 0 && entry[nlen] == '=') {
            return entry + nlen + 1;
        }
    }
    return NULL;
}

#ifndef DB_TERMUX_ADAPT_TESTING

static volatile int g_ctor_done = 0;

static int (*real_open)(const char *, int, ...) = NULL;
static int (*real_open64)(const char *, int, ...) = NULL;
static int (*real_openat)(int, const char *, int, ...) = NULL;
static int (*real_openat64)(int, const char *, int, ...) = NULL;
static int (*real___open_2)(const char *, int) = NULL;
static int (*real___openat_2)(int, const char *, int) = NULL;
static int (*real_creat)(const char *, mode_t) = NULL;
static FILE *(*real_fopen)(const char *, const char *) = NULL;
static FILE *(*real_freopen)(const char *, const char *, FILE *) = NULL;
static int (*real_stat)(const char *, struct stat *) = NULL;
static int (*real_lstat)(const char *, struct stat *) = NULL;
static int (*real_fstatat)(int, const char *, struct stat *, int) = NULL;
#ifdef __ANDROID__
static int (*real_stat64)(const char *, struct stat64 *) = NULL;
static int (*real_lstat64)(const char *, struct stat64 *) = NULL;
static int (*real_fstatat64)(int, const char *, struct stat64 *, int) = NULL;
#endif
static int (*real_faccessat)(int, const char *, int, int) = NULL;
static ssize_t (*real_readlink)(const char *, char *, size_t) = NULL;
static ssize_t (*real_readlinkat)(int, const char *, char *, size_t) = NULL;
static DIR *(*real_opendir)(const char *) = NULL;
static int (*real_mkdir)(const char *, mode_t) = NULL;
static int (*real_mkdirat)(int, const char *, mode_t) = NULL;
static int (*real_rmdir)(const char *) = NULL;
static int (*real_unlink)(const char *) = NULL;
static int (*real_unlinkat)(int, const char *, int) = NULL;
static int (*real_remove)(const char *) = NULL;
static int (*real_rename)(const char *, const char *) = NULL;
static int (*real_renameat)(int, const char *, int, const char *) = NULL;
static int (*real_link)(const char *, const char *) = NULL;
static int (*real_linkat)(int, const char *, int, const char *, int) = NULL;
static int (*real_symlink)(const char *, const char *) = NULL;
static int (*real_symlinkat)(const char *, int, const char *) = NULL;
static int (*real_chmod)(const char *, mode_t) = NULL;
static int (*real_fchmodat)(int, const char *, mode_t, int) = NULL;
static int (*real_chown)(const char *, uid_t, gid_t) = NULL;
static int (*real_lchown)(const char *, uid_t, gid_t) = NULL;
static int (*real_fchownat)(int, const char *, uid_t, gid_t, int) = NULL;
static int (*real_utimensat)(int, const char *, const struct timespec[2], int) = NULL;
static int (*real_truncate)(const char *, off_t) = NULL;
static int (*real_chdir)(const char *) = NULL;
static char *(*real_realpath)(const char *, char *) = NULL;
static int (*real_execve)(const char *, char *const[], char *const[]) = NULL;
static int (*real_execv)(const char *, char *const[]) = NULL;
static int (*real_execvp)(const char *, char *const[]) = NULL;

static void *resolve_sym(void *libc_handle, const char *name) {
    void *sym = dlsym(RTLD_NEXT, name);
    if (!sym && libc_handle) {
        sym = dlsym(libc_handle, name);
    }
    return sym;
}

__attribute__((constructor(101)))
static void init_real_fns(void) {
    if (__atomic_load_n(&g_ctor_done, __ATOMIC_ACQUIRE)) return;
#ifdef __ANDROID__
    void *libc_handle = dlopen("libc.so", RTLD_LAZY | RTLD_NOLOAD);
#else
    void *libc_handle = dlopen("libc.so.6", RTLD_LAZY | RTLD_NOLOAD);
#endif
    real_open = resolve_sym(libc_handle, "open");
    real_open64 = resolve_sym(libc_handle, "open64");
    real_openat = resolve_sym(libc_handle, "openat");
    real_openat64 = resolve_sym(libc_handle, "openat64");
    real___open_2 = resolve_sym(libc_handle, "__open_2");
    real___openat_2 = resolve_sym(libc_handle, "__openat_2");
    real_creat = resolve_sym(libc_handle, "creat");
    real_fopen = resolve_sym(libc_handle, "fopen");
    real_freopen = resolve_sym(libc_handle, "freopen");
    real_stat = resolve_sym(libc_handle, "stat");
    real_lstat = resolve_sym(libc_handle, "lstat");
    real_fstatat = resolve_sym(libc_handle, "fstatat");
#ifdef __ANDROID__
    real_stat64 = resolve_sym(libc_handle, "stat64");
    real_lstat64 = resolve_sym(libc_handle, "lstat64");
    real_fstatat64 = resolve_sym(libc_handle, "fstatat64");
#endif
    real_access = resolve_sym(libc_handle, "access");
    real_faccessat = resolve_sym(libc_handle, "faccessat");
    real_readlink = resolve_sym(libc_handle, "readlink");
    real_readlinkat = resolve_sym(libc_handle, "readlinkat");
    real_opendir = resolve_sym(libc_handle, "opendir");
    real_mkdir = resolve_sym(libc_handle, "mkdir");
    real_mkdirat = resolve_sym(libc_handle, "mkdirat");
    real_rmdir = resolve_sym(libc_handle, "rmdir");
    real_unlink = resolve_sym(libc_handle, "unlink");
    real_unlinkat = resolve_sym(libc_handle, "unlinkat");
    real_remove = resolve_sym(libc_handle, "remove");
    real_rename = resolve_sym(libc_handle, "rename");
    real_renameat = resolve_sym(libc_handle, "renameat");
    real_link = resolve_sym(libc_handle, "link");
    real_linkat = resolve_sym(libc_handle, "linkat");
    real_symlink = resolve_sym(libc_handle, "symlink");
    real_symlinkat = resolve_sym(libc_handle, "symlinkat");
    real_chmod = resolve_sym(libc_handle, "chmod");
    real_fchmodat = resolve_sym(libc_handle, "fchmodat");
    real_chown = resolve_sym(libc_handle, "chown");
    real_lchown = resolve_sym(libc_handle, "lchown");
    real_fchownat = resolve_sym(libc_handle, "fchownat");
    real_utimensat = resolve_sym(libc_handle, "utimensat");
    real_truncate = resolve_sym(libc_handle, "truncate");
    real_chdir = resolve_sym(libc_handle, "chdir");
    real_realpath = resolve_sym(libc_handle, "realpath");
    real_execve = resolve_sym(libc_handle, "execve");
    real_execv = resolve_sym(libc_handle, "execv");
    real_execvp = resolve_sym(libc_handle, "execvp");
    __atomic_store_n(&g_ctor_done, 1, __ATOMIC_RELEASE);
}

#endif

static const char *get_env_nonempty(const char *name) {
    const char *v = safe_getenv(name);
    return (v && v[0] == '/') ? v : NULL;
}

static bool match_prefix(const char *path, const char *prefix, const char **suffix_out) {
    size_t plen = strlen(prefix);
    if (strncmp(path, prefix, plen) != 0) return false;
    if (path[plen] != '\0' && path[plen] != '/') return false;
    *suffix_out = path + plen;
    return true;
}

static const char *join_prefix(const char *target_root, const char *suffix, char *buf, size_t buf_sz, const char *fallback) {
    if (!target_root || target_root[0] != '/') return fallback;
    size_t rlen = strlen(target_root);
    while (rlen > 1 && target_root[rlen - 1] == '/') rlen--;
    size_t slen = strlen(suffix);
    if (rlen + slen + 1 > buf_sz) return fallback;
    memcpy(buf, target_root, rlen);
    memcpy(buf + rlen, suffix, slen + 1);
    return buf;
}

static bool rootfs_from_prefix(const char *prefix, char *buf, size_t buf_sz) {
    if (!prefix || prefix[0] != '/') return false;
    size_t len = strlen(prefix);
    while (len > 1 && prefix[len - 1] == '/') len--;
    if (len > 4 && strncmp(prefix + len - 4, "/usr", 4) == 0) {
        size_t rlen = len - 4;
        if (rlen + 1 > buf_sz) return false;
        memcpy(buf, prefix, rlen);
        buf[rlen] = '\0';
        return true;
    }
    return false;
}

static bool datadir_from_prefix(const char *prefix, char *buf, size_t buf_sz) {
    char rootfs[PATH_MAX];
    if (!rootfs_from_prefix(prefix, rootfs, sizeof(rootfs))) return false;
    size_t len = strlen(rootfs);
    if (len > 6 && strncmp(rootfs + len - 6, "/files", 6) == 0) {
        size_t dlen = len - 6;
        if (dlen + 1 > buf_sz) return false;
        memcpy(buf, rootfs, dlen);
        buf[dlen] = '\0';
        return true;
    }
    return false;
}

const char *db_adapt_translate_path(const char *path, char *buf, size_t buf_sz, bool for_exec) {
    if (!path || path[0] != '/' || buf_sz == 0) return path;
    const char *legacy = NULL;
    if (!match_prefix(path, "/data/data/com.termux", &legacy)) {
        match_prefix(path, "/data/user/0/com.termux", &legacy);
    }

    const char *bin = NULL;
    if (for_exec) {
        if (strncmp(path, "/bin/", 5) == 0) bin = path;
        if (strncmp(path, "/usr/bin/", 9) == 0) bin = path + 4;
        if (bin && (!bin[5] || strchr(bin + 5, '/'))) bin = NULL;
    }
    if (!legacy && !bin) return path;

    const char *disabled = safe_getenv("DB_TERMUX_ADAPT_DISABLE");
    if (disabled && disabled[0] == '1' && disabled[1] == '\0') return path;

    const char *prefix = get_env_nonempty("TERMUX__PREFIX");
    if (!prefix) prefix = get_env_nonempty("PREFIX");

    const char *suffix = NULL;
    if (legacy && match_prefix(legacy, "/files/usr", &suffix)) {
        return join_prefix(prefix, suffix, buf, buf_sz, path);
    }
    if (legacy && match_prefix(legacy, "/files/home", &suffix)) {
        const char *home = get_env_nonempty("TERMUX__HOME");
        if (!home) home = get_env_nonempty("HOME");
        return join_prefix(home, suffix, buf, buf_sz, path);
    }
    if (legacy && match_prefix(legacy, "/cache", &suffix)) {
        const char *cache = get_env_nonempty("TERMUX__CACHE_DIR");
        if (!cache) cache = get_env_nonempty("TERMUX_CACHE_DIR");
        return join_prefix(cache, suffix, buf, buf_sz, path);
    }
    if (legacy && match_prefix(legacy, "/files", &suffix)) {
        char rootfs[PATH_MAX];
        const char *rf = get_env_nonempty("TERMUX__ROOTFS");
        if (!rf && rootfs_from_prefix(prefix, rootfs, sizeof(rootfs))) rf = rootfs;
        return join_prefix(rf, suffix, buf, buf_sz, path);
    }
    if (legacy) {
        char ddir[PATH_MAX];
        const char *dd = get_env_nonempty("TERMUX_APP__DATA_DIR");
        if (!dd && datadir_from_prefix(prefix, ddir, sizeof(ddir))) dd = ddir;
        return join_prefix(dd, legacy, buf, buf_sz, path);
    }

    if (bin && prefix) {
        const char *cand = join_prefix(prefix, bin, buf, buf_sz, NULL);
        if (cand && (real_access ? real_access(cand, X_OK) : sys_access_fallback(cand, X_OK)) == 0) {
            return cand;
        }
#ifdef __ANDROID__
        cand = join_prefix("/system", bin, buf, buf_sz, NULL);
        if (cand && (real_access ? real_access(cand, X_OK) : sys_access_fallback(cand, X_OK)) == 0) {
            return cand;
        }
#endif
    }
    return path;
}

#ifndef DB_TERMUX_ADAPT_TESTING

static const char *translate(const char *path, char *buf, size_t buf_sz) {
    return db_adapt_translate_path(path, buf, buf_sz, false);
}

static const char *translate_exec(const char *path, char *buf, size_t buf_sz) {
    return db_adapt_translate_path(path, buf, buf_sz, true);
}

static int call_open(const char *p, int flags, mode_t mode, bool has_mode) {
    if (real_open) {
        return has_mode ? real_open(p, flags, mode) : real_open(p, flags);
    }
#ifdef SYS_openat
    return (int)syscall(SYS_openat, AT_FDCWD, p, flags, has_mode ? mode : 0);
#else
    (void)p; (void)flags; (void)mode; (void)has_mode;
    errno = ENOSYS;
    return -1;
#endif
}

static int call_openat(int dirfd, const char *p, int flags, mode_t mode, bool has_mode) {
    if (real_openat) {
        return has_mode ? real_openat(dirfd, p, flags, mode) : real_openat(dirfd, p, flags);
    }
#ifdef SYS_openat
    return (int)syscall(SYS_openat, dirfd, p, flags, has_mode ? mode : 0);
#else
    (void)dirfd; (void)p; (void)flags; (void)mode; (void)has_mode;
    errno = ENOSYS;
    return -1;
#endif
}

static bool open_needs_mode(int flags) {
    return (flags & O_CREAT) || (flags & O_TMPFILE) == O_TMPFILE;
}

int open(const char *pathname, int flags, ...) {
    char buf[PATH_MAX];
    const char *p = translate(pathname, buf, sizeof(buf));
    if (open_needs_mode(flags)) {
        va_list ap;
        va_start(ap, flags);
        mode_t mode = (mode_t)va_arg(ap, int);
        va_end(ap);
        return call_open(p, flags, mode, true);
    }
    return call_open(p, flags, 0, false);
}

int open64(const char *pathname, int flags, ...) {
    char buf[PATH_MAX];
    const char *p = translate(pathname, buf, sizeof(buf));
    int (*fn)(const char *, int, ...) = real_open64 ? real_open64 : real_open;
    if (open_needs_mode(flags)) {
        va_list ap;
        va_start(ap, flags);
        mode_t mode = (mode_t)va_arg(ap, int);
        va_end(ap);
        return fn ? fn(p, flags, mode) : call_open(p, flags, mode, true);
    }
    return fn ? fn(p, flags) : call_open(p, flags, 0, false);
}

int openat(int dirfd, const char *pathname, int flags, ...) {
    char buf[PATH_MAX];
    const char *p = translate(pathname, buf, sizeof(buf));
    if (open_needs_mode(flags)) {
        va_list ap;
        va_start(ap, flags);
        mode_t mode = (mode_t)va_arg(ap, int);
        va_end(ap);
        return call_openat(dirfd, p, flags, mode, true);
    }
    return call_openat(dirfd, p, flags, 0, false);
}

int openat64(int dirfd, const char *pathname, int flags, ...) {
    char buf[PATH_MAX];
    const char *p = translate(pathname, buf, sizeof(buf));
    int (*fn)(int, const char *, int, ...) = real_openat64 ? real_openat64 : real_openat;
    if (open_needs_mode(flags)) {
        va_list ap;
        va_start(ap, flags);
        mode_t mode = (mode_t)va_arg(ap, int);
        va_end(ap);
        return fn ? fn(dirfd, p, flags, mode) : call_openat(dirfd, p, flags, mode, true);
    }
    return fn ? fn(dirfd, p, flags) : call_openat(dirfd, p, flags, 0, false);
}

int __open_2(const char *pathname, int flags) {
    char buf[PATH_MAX];
    const char *p = translate(pathname, buf, sizeof(buf));
    if (real___open_2) return real___open_2(p, flags);
    return call_open(p, flags, 0, false);
}

int __openat_2(int dirfd, const char *pathname, int flags) {
    char buf[PATH_MAX];
    const char *p = translate(pathname, buf, sizeof(buf));
    if (real___openat_2) return real___openat_2(dirfd, p, flags);
    return call_openat(dirfd, p, flags, 0, false);
}

int creat(const char *pathname, mode_t mode) {
    char buf[PATH_MAX];
    const char *p = translate(pathname, buf, sizeof(buf));
    if (real_creat) return real_creat(p, mode);
    return call_open(p, O_CREAT | O_WRONLY | O_TRUNC, mode, true);
}

FILE *fopen(const char *pathname, const char *mode) {
    char buf[PATH_MAX];
    if (!real_fopen) { errno = ENOSYS; return NULL; }
    return real_fopen(translate(pathname, buf, sizeof(buf)), mode);
}

FILE *freopen(const char *pathname, const char *mode, FILE *stream) {
    char buf[PATH_MAX];
    if (!real_freopen) { errno = ENOSYS; return NULL; }
    return real_freopen(translate(pathname, buf, sizeof(buf)), mode, stream);
}

int stat(const char *pathname, struct stat *statbuf) {
    char buf[PATH_MAX];
    const char *p = translate(pathname, buf, sizeof(buf));
    if (real_stat) return real_stat(p, statbuf);
    if (real_fstatat) return real_fstatat(AT_FDCWD, p, statbuf, 0);
    errno = ENOSYS;
    return -1;
}

int lstat(const char *pathname, struct stat *statbuf) {
    char buf[PATH_MAX];
    const char *p = translate(pathname, buf, sizeof(buf));
    if (real_lstat) return real_lstat(p, statbuf);
    if (real_fstatat) return real_fstatat(AT_FDCWD, p, statbuf, AT_SYMLINK_NOFOLLOW);
    errno = ENOSYS;
    return -1;
}

int fstatat(int dirfd, const char *pathname, struct stat *statbuf, int flags) {
    char buf[PATH_MAX];
    if (!real_fstatat) { errno = ENOSYS; return -1; }
    return real_fstatat(dirfd, translate(pathname, buf, sizeof(buf)), statbuf, flags);
}

#ifdef __ANDROID__
int stat64(const char *pathname, struct stat64 *statbuf) {
    char buf[PATH_MAX];
    const char *p = translate(pathname, buf, sizeof(buf));
    if (real_stat64) return real_stat64(p, statbuf);
    if (real_fstatat64) return real_fstatat64(AT_FDCWD, p, statbuf, 0);
    errno = ENOSYS;
    return -1;
}

int lstat64(const char *pathname, struct stat64 *statbuf) {
    char buf[PATH_MAX];
    const char *p = translate(pathname, buf, sizeof(buf));
    if (real_lstat64) return real_lstat64(p, statbuf);
    if (real_fstatat64) return real_fstatat64(AT_FDCWD, p, statbuf, AT_SYMLINK_NOFOLLOW);
    errno = ENOSYS;
    return -1;
}

int fstatat64(int dirfd, const char *pathname, struct stat64 *statbuf, int flags) {
    char buf[PATH_MAX];
    if (!real_fstatat64) { errno = ENOSYS; return -1; }
    return real_fstatat64(dirfd, translate(pathname, buf, sizeof(buf)), statbuf, flags);
}
#endif

int access(const char *pathname, int mode) {
    char buf[PATH_MAX];
    const char *p = translate(pathname, buf, sizeof(buf));
    if (real_access) return real_access(p, mode);
    return sys_access_fallback(p, mode);
}

int faccessat(int dirfd, const char *pathname, int mode, int flags) {
    char buf[PATH_MAX];
    const char *p = translate(pathname, buf, sizeof(buf));
    if (real_faccessat) return real_faccessat(dirfd, p, mode, flags);
#ifdef SYS_faccessat
    if (flags == 0) return (int)syscall(SYS_faccessat, dirfd, p, mode);
#endif
    errno = ENOSYS;
    return -1;
}

ssize_t readlink(const char *pathname, char *out, size_t bufsiz) {
    char buf[PATH_MAX];
    const char *p = translate(pathname, buf, sizeof(buf));
    if (real_readlink) return real_readlink(p, out, bufsiz);
#ifdef SYS_readlinkat
    return (ssize_t)syscall(SYS_readlinkat, AT_FDCWD, p, out, bufsiz);
#else
    errno = ENOSYS;
    return -1;
#endif
}

ssize_t readlinkat(int dirfd, const char *pathname, char *out, size_t bufsiz) {
    char buf[PATH_MAX];
    const char *p = translate(pathname, buf, sizeof(buf));
    if (real_readlinkat) return real_readlinkat(dirfd, p, out, bufsiz);
#ifdef SYS_readlinkat
    return (ssize_t)syscall(SYS_readlinkat, dirfd, p, out, bufsiz);
#else
    errno = ENOSYS;
    return -1;
#endif
}

DIR *opendir(const char *name) {
    char buf[PATH_MAX];
    if (!real_opendir) { errno = ENOSYS; return NULL; }
    return real_opendir(translate(name, buf, sizeof(buf)));
}

int mkdir(const char *pathname, mode_t mode) {
    char buf[PATH_MAX];
    const char *p = translate(pathname, buf, sizeof(buf));
    if (real_mkdir) return real_mkdir(p, mode);
#ifdef SYS_mkdirat
    return (int)syscall(SYS_mkdirat, AT_FDCWD, p, mode);
#else
    errno = ENOSYS;
    return -1;
#endif
}

int mkdirat(int dirfd, const char *pathname, mode_t mode) {
    char buf[PATH_MAX];
    const char *p = translate(pathname, buf, sizeof(buf));
    if (real_mkdirat) return real_mkdirat(dirfd, p, mode);
#ifdef SYS_mkdirat
    return (int)syscall(SYS_mkdirat, dirfd, p, mode);
#else
    errno = ENOSYS;
    return -1;
#endif
}

int rmdir(const char *pathname) {
    char buf[PATH_MAX];
    const char *p = translate(pathname, buf, sizeof(buf));
    if (real_rmdir) return real_rmdir(p);
#ifdef SYS_unlinkat
    return (int)syscall(SYS_unlinkat, AT_FDCWD, p, AT_REMOVEDIR);
#else
    errno = ENOSYS;
    return -1;
#endif
}

int unlink(const char *pathname) {
    char buf[PATH_MAX];
    const char *p = translate(pathname, buf, sizeof(buf));
    if (real_unlink) return real_unlink(p);
#ifdef SYS_unlinkat
    return (int)syscall(SYS_unlinkat, AT_FDCWD, p, 0);
#else
    errno = ENOSYS;
    return -1;
#endif
}

int unlinkat(int dirfd, const char *pathname, int flags) {
    char buf[PATH_MAX];
    const char *p = translate(pathname, buf, sizeof(buf));
    if (real_unlinkat) return real_unlinkat(dirfd, p, flags);
#ifdef SYS_unlinkat
    return (int)syscall(SYS_unlinkat, dirfd, p, flags);
#else
    errno = ENOSYS;
    return -1;
#endif
}

int remove(const char *pathname) {
    char buf[PATH_MAX];
    const char *p = translate(pathname, buf, sizeof(buf));
    if (real_remove) return real_remove(p);
    if (real_unlink && real_unlink(p) == 0) return 0;
    if (errno == EISDIR && real_rmdir) return real_rmdir(p);
    errno = ENOSYS;
    return -1;
}

int rename(const char *oldpath, const char *newpath) {
    char b1[PATH_MAX], b2[PATH_MAX];
    if (!real_rename) { errno = ENOSYS; return -1; }
    return real_rename(translate(oldpath, b1, sizeof(b1)), translate(newpath, b2, sizeof(b2)));
}

int renameat(int olddirfd, const char *oldpath, int newdirfd, const char *newpath) {
    char b1[PATH_MAX], b2[PATH_MAX];
    if (!real_renameat) { errno = ENOSYS; return -1; }
    return real_renameat(olddirfd, translate(oldpath, b1, sizeof(b1)), newdirfd, translate(newpath, b2, sizeof(b2)));
}

int link(const char *oldpath, const char *newpath) {
    char b1[PATH_MAX], b2[PATH_MAX];
    if (!real_link) { errno = ENOSYS; return -1; }
    return real_link(translate(oldpath, b1, sizeof(b1)), translate(newpath, b2, sizeof(b2)));
}

int linkat(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, int flags) {
    char b1[PATH_MAX], b2[PATH_MAX];
    if (!real_linkat) { errno = ENOSYS; return -1; }
    return real_linkat(olddirfd, translate(oldpath, b1, sizeof(b1)), newdirfd, translate(newpath, b2, sizeof(b2)), flags);
}

int symlink(const char *target, const char *linkpath) {
    char b1[PATH_MAX], b2[PATH_MAX];
    if (!real_symlink) { errno = ENOSYS; return -1; }
    return real_symlink(translate(target, b1, sizeof(b1)), translate(linkpath, b2, sizeof(b2)));
}

int symlinkat(const char *target, int newdirfd, const char *linkpath) {
    char b1[PATH_MAX], b2[PATH_MAX];
    if (!real_symlinkat) { errno = ENOSYS; return -1; }
    return real_symlinkat(translate(target, b1, sizeof(b1)), newdirfd, translate(linkpath, b2, sizeof(b2)));
}

int chmod(const char *pathname, mode_t mode) {
    char buf[PATH_MAX];
    if (!real_chmod) { errno = ENOSYS; return -1; }
    return real_chmod(translate(pathname, buf, sizeof(buf)), mode);
}

int fchmodat(int dirfd, const char *pathname, mode_t mode, int flags) {
    char buf[PATH_MAX];
    if (!real_fchmodat) { errno = ENOSYS; return -1; }
    return real_fchmodat(dirfd, translate(pathname, buf, sizeof(buf)), mode, flags);
}

int chown(const char *pathname, uid_t owner, gid_t group) {
    char buf[PATH_MAX];
    if (!real_chown) { errno = ENOSYS; return -1; }
    return real_chown(translate(pathname, buf, sizeof(buf)), owner, group);
}

int lchown(const char *pathname, uid_t owner, gid_t group) {
    char buf[PATH_MAX];
    if (!real_lchown) { errno = ENOSYS; return -1; }
    return real_lchown(translate(pathname, buf, sizeof(buf)), owner, group);
}

int fchownat(int dirfd, const char *pathname, uid_t owner, gid_t group, int flags) {
    char buf[PATH_MAX];
    if (!real_fchownat) { errno = ENOSYS; return -1; }
    return real_fchownat(dirfd, translate(pathname, buf, sizeof(buf)), owner, group, flags);
}

int utimensat(int dirfd, const char *pathname, const struct timespec times[2], int flags) {
    char buf[PATH_MAX];
    if (!real_utimensat) { errno = ENOSYS; return -1; }
    return real_utimensat(dirfd, translate(pathname, buf, sizeof(buf)), times, flags);
}

int truncate(const char *pathname, off_t length) {
    char buf[PATH_MAX];
    if (!real_truncate) { errno = ENOSYS; return -1; }
    return real_truncate(translate(pathname, buf, sizeof(buf)), length);
}

int chdir(const char *path) {
    char buf[PATH_MAX];
    const char *p = translate(path, buf, sizeof(buf));
    if (real_chdir) return real_chdir(p);
#ifdef SYS_chdir
    return (int)syscall(SYS_chdir, p);
#else
    errno = ENOSYS;
    return -1;
#endif
}

char *realpath(const char *path, char *resolved_path) {
    char buf[PATH_MAX];
    if (!real_realpath) { errno = ENOSYS; return NULL; }
    return real_realpath(translate(path, buf, sizeof(buf)), resolved_path);
}

static int call_execve(const char *path, char *const argv[], char *const envp[]) {
    if (real_execve) return real_execve(path, argv, envp);
#ifdef SYS_execve
    return (int)syscall(SYS_execve, path, argv, envp);
#else
    (void)path; (void)argv; (void)envp;
    errno = ENOSYS;
    return -1;
#endif
}

int execve(const char *pathname, char *const argv[], char *const envp[]) {
    char pbuf[PATH_MAX];
    const char *target = translate_exec(pathname, pbuf, sizeof(pbuf));

    /* Check script shebangs so #!/bin/sh or #!/data/data/com.termux/... work without patching on disk. */
    int fd = call_open(target, O_RDONLY | O_CLOEXEC | O_NONBLOCK, 0, false);
    if (fd >= 0) {
        char head[256];
        ssize_t n = read(fd, head, sizeof(head) - 1);
        close(fd);
        if (n > 2 && head[0] == '#' && head[1] == '!' &&
            (real_access ? real_access(target, X_OK) : sys_access_fallback(target, X_OK)) == 0) {
            head[n] = '\0';
            char *nl = strpbrk(head, "\r\n");
            if (nl) *nl = '\0';
            char *interp = head + 2;
            while (*interp == ' ' || *interp == '\t') interp++;
            char *arg = NULL;
            char *sp = interp;
            while (*sp && *sp != ' ' && *sp != '\t') sp++;
            if (*sp) {
                *sp++ = '\0';
                while (*sp == ' ' || *sp == '\t') sp++;
                if (*sp) arg = sp;
            }
            if (interp[0] == '/') {
                char ibuf[PATH_MAX];
                const char *new_interp = translate_exec(interp, ibuf, sizeof(ibuf));
                if (new_interp != interp) {
                    size_t argc = 0;
                    while (argv[argc]) argc++;
                    size_t extra = arg ? 2 : 1;
                    char **new_argv = calloc(argc + extra + 1, sizeof(char *));
                    if (new_argv) {
                        size_t idx = 0;
                        new_argv[idx++] = (char *)new_interp;
                        if (arg) new_argv[idx++] = arg;
                        new_argv[idx++] = (char *)target;
                        for (size_t i = 1; i < argc; i++) new_argv[idx++] = argv[i];
                        new_argv[idx] = NULL;
                        int rc = call_execve(new_interp, new_argv, envp);
                        int saved = errno;
                        free(new_argv);
                        errno = saved;
                        return rc;
                    }
                }
            }
        }
    }
    return call_execve(target, argv, envp);
}

int execv(const char *pathname, char *const argv[]) {
    return execve(pathname, argv, environ);
}

int execvp(const char *file, char *const argv[]) {
    if (strchr(file, '/') != NULL) {
        return execve(file, argv, environ);
    }
    const char *path_env = safe_getenv("PATH");
    if (!path_env) path_env = "/system/bin";
    size_t flen = strlen(file);
    const char *cur = path_env;
    int last_err = ENOENT;
    while (*cur) {
        const char *colon = strchr(cur, ':');
        size_t dlen = colon ? (size_t)(colon - cur) : strlen(cur);
        if (dlen > 0 && dlen + 1 + flen + 1 <= PATH_MAX) {
            char cand[PATH_MAX];
            memcpy(cand, cur, dlen);
            cand[dlen] = '/';
            memcpy(cand + dlen + 1, file, flen + 1);
            execve(cand, argv, environ);
            if (errno != ENOENT && errno != ENOTDIR && errno != EACCES) {
                return -1;
            }
            if (errno == EACCES) last_err = EACCES;
        }
        if (!colon) break;
        cur = colon + 1;
    }
    errno = last_err;
    return -1;
}

#endif
