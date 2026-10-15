/* Building PHP extensions with zig's clang (x86_64-windows-gnu) for PHP's
 * official Windows builds, which MSVC builds. php-ext force-includes this
 * (-include) ahead of an extension's sources, and compiles with
 * -fms-extensions, which gives clang the MSVC intrinsics that
 * zend_atomic.h uses (_InterlockedExchange8...) and makes
 * __declspec(thread) real thread-local storage, as TSRM_TLS needs in
 * thread-safe builds. */
#ifndef ZIGSAW_ZIG_PHP_H
#define ZIGSAW_ZIG_PHP_H

/* php.h declares pid_t as int, as MSVC has none; MinGW's sys/types.h
 * declares a 64-bit one first. */
#define _PID_T_

/* PHP's win32/time.h defines struct timezone, as MSVC has none; MinGW's
 * time.h defines the same one first. */
#define _TIMEZONE_DEFINED

/* gettimeofday is php8.dll's, which win32/time.h declares; MinGW's
 * sys/time.h declares its own, with another signature. */
#define _GETTIMEOFDAY_DEFINED

/* PHP's ext/standard/php_filestat.h defines S_IRUSR ... S_IXOTH from
 * S_IREAD, S_IWRITE and S_IEXEC, as MSVC has none; MinGW's sys/stat.h has
 * its own, by Unix's bits, which PHP's then redefine with a warning in
 * every file. They're left to PHP's, as with MSVC. */
#include <sys/stat.h>
#undef S_IRUSR
#undef S_IWUSR
#undef S_IXUSR
#undef S_IRGRP
#undef S_IWGRP
#undef S_IXGRP
#undef S_IROTH
#undef S_IWOTH
#undef S_IXOTH

/* POSIX names MinGW's headers define and MSVC's don't, which extensions
 * test for: with them, code takes another branch than in MSVC builds of
 * it. Xdebug's default output directory is P_tmpdir when there is one,
 * "\\" with MinGW (the current drive's root, where a user may not write),
 * C:\Windows\Temp otherwise; PATH_MAX and NAME_MAX size buffers. */
#include <stdio.h>
#include <limits.h>
#undef P_tmpdir
#undef PATH_MAX
#undef NAME_MAX

#include "zend_portability.h"

/* php8.dll's ZEND_FASTCALL functions (_emalloc, zend_hash_find...) and the
 * handlers it calls (PHP_FUNCTION) are __vectorcall, which MSVC builds use
 * and which decorates their names (_emalloc@@8). zend_portability.h picks
 * it only when _MSC_VER is defined; clang has it too. */
#undef ZEND_FASTCALL
#define ZEND_FASTCALL __vectorcall

/* With __builtin_constant_p, zend_alloc.h calls a size-class allocator
 * for each constant size (_emalloc_40...); MSVC has no such builtin, so
 * php8.dll doesn't have them. Without it, emalloc calls _emalloc. */
#undef HAVE_BUILTIN_CONSTANT_P

#endif
