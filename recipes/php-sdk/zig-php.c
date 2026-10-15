/* Linked into every PHP extension php-ext builds: what PHP's headers expect
 * php8.dll to export for GCC and clang, which MSVC builds of PHP don't.
 * Compiled with the extension's flags, zig-php.h included. */
#include "php.h"

/* zend_string.h declares zend_string_equal_val as one of php8.dll's
 * functions for GCC and clang on x86, where PHP's own build has it in
 * assembly; MSVC builds inline it instead, so php8.dll lacks it. The
 * extension's calls go through __imp_zend_string_equal_val@@16, the
 * pointer a dllimport call reads, so this defines that pointer, to the body
 * MSVC builds inline. */
static bool ZEND_FASTCALL equal_val(const zend_string *s1, const zend_string *s2)
{
	return !memcmp(ZSTR_VAL(s1), ZSTR_VAL(s2), ZSTR_LEN(s1));
}

bool (ZEND_FASTCALL *const zigsaw_imp_zend_string_equal_val)(const zend_string *, const zend_string *)
	__asm__("__imp_zend_string_equal_val@@16") = equal_val;
