/* zigsaw's test extension: PHP's C API, as an extension that php-ext builds
 * with zig uses it from PHP's official build, which MSVC builds. test.php
 * calls each function. */
#include "php.h"
#include "php_ini.h"
#include "ext/standard/info.h"
#include "zend_exceptions.h"
#include "zend_smart_str.h"
#include "zend_interfaces.h"
#include "greet.h"

ZEND_BEGIN_MODULE_GLOBALS(zprobe)
	zend_long calls;
	char *greeting;
	bool bailed;
ZEND_END_MODULE_GLOBALS(zprobe)

ZEND_DECLARE_MODULE_GLOBALS(zprobe)
#define ZPROBE_G(v) ZEND_MODULE_GLOBALS_ACCESSOR(zprobe, v)

#if defined(ZTS) && defined(COMPILE_DL_ZPROBE)
ZEND_TSRMLS_CACHE_DEFINE()
#endif

PHP_INI_BEGIN()
	STD_PHP_INI_ENTRY("zprobe.greeting", "hello", PHP_INI_ALL, OnUpdateString, greeting, zend_zprobe_globals, zprobe_globals)
PHP_INI_END()

static zend_class_entry *zprobe_point_ce;
static zend_object_handlers zprobe_point_handlers;

typedef struct {
	double weight;
	zend_object std;
} zprobe_point;

static inline zprobe_point *point_from(zend_object *obj)
{
	return (zprobe_point *)((char *)obj - XtOffsetOf(zprobe_point, std));
}

static zend_object *point_create(zend_class_entry *ce)
{
	zprobe_point *p = zend_object_alloc(sizeof(zprobe_point), ce);
	p->weight = 1.5;
	zend_object_std_init(&p->std, ce);
	object_properties_init(&p->std, ce);
	p->std.handlers = &zprobe_point_handlers;
	return &p->std;
}

static void point_free(zend_object *obj)
{
	zend_object_std_dtor(obj);
}

/* string zprobe_compiler() */
PHP_FUNCTION(zprobe_compiler)
{
	ZEND_PARSE_PARAMETERS_NONE();
	ZPROBE_G(calls)++;
#if defined(__clang__)
	RETURN_STRING("clang " __clang_version__);
#elif defined(_MSC_VER)
	RETURN_STR(zend_strpprintf(0, "MSVC %d", _MSC_VER));
#else
	RETURN_STRING("unknown");
#endif
}

/* string zprobe_repeat(string $s, int $n, string $sep = ",") */
PHP_FUNCTION(zprobe_repeat)
{
	zend_string *s, *sep = NULL;
	zend_long n;
	smart_str out = {0};

	ZEND_PARSE_PARAMETERS_START(2, 3)
		Z_PARAM_STR(s)
		Z_PARAM_LONG(n)
		Z_PARAM_OPTIONAL
		Z_PARAM_STR(sep)
	ZEND_PARSE_PARAMETERS_END();

	ZPROBE_G(calls)++;
	for (zend_long i = 0; i < n; i++) {
		if (i) {
			if (sep) smart_str_append(&out, sep);
			else smart_str_appendc(&out, ',');
		}
		smart_str_append(&out, s);
	}
	smart_str_0(&out);
	if (!out.s) RETURN_EMPTY_STRING();
	RETURN_STR(smart_str_extract(&out));
}

/* float zprobe_sum(array $a) */
PHP_FUNCTION(zprobe_sum)
{
	HashTable *ht;
	zval *v;
	double sum = 0;

	ZEND_PARSE_PARAMETERS_START(1, 1)
		Z_PARAM_ARRAY_HT(ht)
	ZEND_PARSE_PARAMETERS_END();

	ZEND_HASH_FOREACH_VAL(ht, v) {
		sum += zval_get_double(v);
	} ZEND_HASH_FOREACH_END();
	RETURN_DOUBLE(sum);
}

/* array zprobe_map(array $a, callable $f): keys kept, values f($v, $k) */
PHP_FUNCTION(zprobe_map)
{
	HashTable *ht;
	zend_fcall_info fci;
	zend_fcall_info_cache fcc;
	zend_string *key;
	zend_ulong idx;
	zval *v;

	ZEND_PARSE_PARAMETERS_START(2, 2)
		Z_PARAM_ARRAY_HT(ht)
		Z_PARAM_FUNC(fci, fcc)
	ZEND_PARSE_PARAMETERS_END();

	array_init_size(return_value, zend_hash_num_elements(ht));
	ZEND_HASH_FOREACH_KEY_VAL(ht, idx, key, v) {
		zval args[2], ret;
		ZVAL_COPY(&args[0], v);
		if (key) ZVAL_STR_COPY(&args[1], key);
		else ZVAL_LONG(&args[1], idx);
		fci.retval = &ret;
		fci.params = args;
		fci.param_count = 2;
		zend_result r = zend_call_function(&fci, &fcc);
		zval_ptr_dtor(&args[0]);
		zval_ptr_dtor(&args[1]);
		if (r == FAILURE || EG(exception)) {
			zend_array_destroy(Z_ARR_P(return_value));
			RETURN_NULL();
		}
		if (key) zend_hash_update(Z_ARRVAL_P(return_value), key, &ret);
		else zend_hash_index_update(Z_ARRVAL_P(return_value), idx, &ret);
	} ZEND_HASH_FOREACH_END();
}

/* never zprobe_throw(string $msg, int $code) */
PHP_FUNCTION(zprobe_throw)
{
	zend_string *msg;
	zend_long code;
	ZEND_PARSE_PARAMETERS_START(2, 2)
		Z_PARAM_STR(msg)
		Z_PARAM_LONG(code)
	ZEND_PARSE_PARAMETERS_END();
	zend_throw_exception(zend_ce_exception, ZSTR_VAL(msg), code);
}

/* void zprobe_guard(callable $f): calls f inside zend_try; on a bailout
 * (fatal error) records it and bails out again */
PHP_FUNCTION(zprobe_guard)
{
	zend_fcall_info fci;
	zend_fcall_info_cache fcc;
	zval ret;

	ZEND_PARSE_PARAMETERS_START(1, 1)
		Z_PARAM_FUNC(fci, fcc)
	ZEND_PARSE_PARAMETERS_END();

	fci.retval = &ret;
	zend_try {
		zend_call_function(&fci, &fcc);
		zval_ptr_dtor(&ret);
	} zend_catch {
		ZPROBE_G(bailed) = 1;
		zend_bailout();
	} zend_end_try();
}

/* bool zprobe_bailed() */
PHP_FUNCTION(zprobe_bailed)
{
	ZEND_PARSE_PARAMETERS_NONE();
	RETURN_BOOL(ZPROBE_G(bailed));
}

/* string zprobe_read(string $path): reads a file through PHP's streams */
PHP_FUNCTION(zprobe_read)
{
	zend_string *path, *data;
	php_stream *stream;

	ZEND_PARSE_PARAMETERS_START(1, 1)
		Z_PARAM_PATH_STR(path)
	ZEND_PARSE_PARAMETERS_END();

	stream = php_stream_open_wrapper(ZSTR_VAL(path), "rb", REPORT_ERRORS, NULL);
	if (!stream) RETURN_FALSE;
	data = php_stream_copy_to_mem(stream, PHP_STREAM_COPY_ALL, 0);
	php_stream_close(stream);
	if (!data) RETURN_EMPTY_STRING();
	RETURN_STR(data);
}

/* string zprobe_format(float $a, int $b, string $s): variadic printf with doubles */
PHP_FUNCTION(zprobe_format)
{
	double a;
	zend_long b;
	zend_string *s;
	ZEND_PARSE_PARAMETERS_START(3, 3)
		Z_PARAM_DOUBLE(a)
		Z_PARAM_LONG(b)
		Z_PARAM_STR(s)
	ZEND_PARSE_PARAMETERS_END();
	RETURN_STR(zend_strpprintf(0, "%.3f|" ZEND_LONG_FMT "|%s|%s|%s", a, b, ZSTR_VAL(s),
		ZSTR_VAL(zend_double_to_str(a)), ZPROBE_G(greeting)));
}

/* string zprobe_config(): what config.w32 set up: an AC_DEFINE string, and a
 * library CHECK_LIB found, called from a source in a subdirectory */
PHP_FUNCTION(zprobe_config)
{
	ZEND_PARSE_PARAMETERS_NONE();
	RETURN_STR(zend_strpprintf(0, "%s, version info: %s", ZPROBE_GREETING,
		zprobe_version_info_size() > 0 ? "yes" : "no"));
}

/* string zprobe_libs(): zlib, libxml2 and OpenSSL, as PHP has them, called */
PHP_FUNCTION(zprobe_libs)
{
	char out[256];
	ZEND_PARSE_PARAMETERS_NONE();
	zprobe_libs(out, sizeof out);
	RETURN_STRING(out);
}

/* int zprobe_calls(): module globals */
PHP_FUNCTION(zprobe_calls)
{
	ZEND_PARSE_PARAMETERS_NONE();
	RETURN_LONG(ZPROBE_G(calls));
}

PHP_METHOD(ZProbe_Point, __construct)
{
	double x, y;
	ZEND_PARSE_PARAMETERS_START(2, 2)
		Z_PARAM_DOUBLE(x)
		Z_PARAM_DOUBLE(y)
	ZEND_PARSE_PARAMETERS_END();
	zend_update_property_double(zprobe_point_ce, Z_OBJ_P(ZEND_THIS), "x", 1, x);
	zend_update_property_double(zprobe_point_ce, Z_OBJ_P(ZEND_THIS), "y", 1, y);
	point_from(Z_OBJ_P(ZEND_THIS))->weight = x + y;
}

PHP_METHOD(ZProbe_Point, length)
{
	zval rv, *x, *y;
	ZEND_PARSE_PARAMETERS_NONE();
	x = zend_read_property(zprobe_point_ce, Z_OBJ_P(ZEND_THIS), "x", 1, 0, &rv);
	double dx = zval_get_double(x);
	y = zend_read_property(zprobe_point_ce, Z_OBJ_P(ZEND_THIS), "y", 1, 0, &rv);
	double dy = zval_get_double(y);
	RETURN_DOUBLE(sqrt(dx * dx + dy * dy));
}

PHP_METHOD(ZProbe_Point, weight)
{
	ZEND_PARSE_PARAMETERS_NONE();
	RETURN_DOUBLE(point_from(Z_OBJ_P(ZEND_THIS))->weight);
}

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_zprobe_compiler, 0, 0, IS_STRING, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_zprobe_repeat, 0, 2, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, s, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, n, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO_WITH_DEFAULT_VALUE(0, sep, IS_STRING, 0, "\",\"")
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_zprobe_sum, 0, 1, IS_DOUBLE, 0)
	ZEND_ARG_TYPE_INFO(0, a, IS_ARRAY, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_zprobe_map, 0, 2, IS_ARRAY, 0)
	ZEND_ARG_TYPE_INFO(0, a, IS_ARRAY, 0)
	ZEND_ARG_TYPE_INFO(0, f, IS_CALLABLE, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_zprobe_throw, 0, 2, IS_NEVER, 0)
	ZEND_ARG_TYPE_INFO(0, msg, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, code, IS_LONG, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_zprobe_guard, 0, 1, IS_VOID, 0)
	ZEND_ARG_TYPE_INFO(0, f, IS_CALLABLE, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_zprobe_bailed, 0, 0, _IS_BOOL, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_INFO_EX(arginfo_zprobe_read, 0, 0, 1)
	ZEND_ARG_TYPE_INFO(0, path, IS_STRING, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_zprobe_format, 0, 3, IS_STRING, 0)
	ZEND_ARG_TYPE_INFO(0, a, IS_DOUBLE, 0)
	ZEND_ARG_TYPE_INFO(0, b, IS_LONG, 0)
	ZEND_ARG_TYPE_INFO(0, s, IS_STRING, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_zprobe_calls, 0, 0, IS_LONG, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_zprobe_config, 0, 0, IS_STRING, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_zprobe_libs, 0, 0, IS_STRING, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_INFO_EX(arginfo_point_construct, 0, 0, 2)
	ZEND_ARG_TYPE_INFO(0, x, IS_DOUBLE, 0)
	ZEND_ARG_TYPE_INFO(0, y, IS_DOUBLE, 0)
ZEND_END_ARG_INFO()
ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_point_double, 0, 0, IS_DOUBLE, 0)
ZEND_END_ARG_INFO()

static const zend_function_entry zprobe_functions[] = {
	PHP_FE(zprobe_compiler, arginfo_zprobe_compiler)
	PHP_FE(zprobe_repeat, arginfo_zprobe_repeat)
	PHP_FE(zprobe_sum, arginfo_zprobe_sum)
	PHP_FE(zprobe_map, arginfo_zprobe_map)
	PHP_FE(zprobe_throw, arginfo_zprobe_throw)
	PHP_FE(zprobe_guard, arginfo_zprobe_guard)
	PHP_FE(zprobe_bailed, arginfo_zprobe_bailed)
	PHP_FE(zprobe_read, arginfo_zprobe_read)
	PHP_FE(zprobe_format, arginfo_zprobe_format)
	PHP_FE(zprobe_calls, arginfo_zprobe_calls)
	PHP_FE(zprobe_config, arginfo_zprobe_config)
	PHP_FE(zprobe_libs, arginfo_zprobe_libs)
	PHP_FE_END
};

static const zend_function_entry point_methods[] = {
	PHP_ME(ZProbe_Point, __construct, arginfo_point_construct, ZEND_ACC_PUBLIC)
	PHP_ME(ZProbe_Point, length, arginfo_point_double, ZEND_ACC_PUBLIC)
	PHP_ME(ZProbe_Point, weight, arginfo_point_double, ZEND_ACC_PUBLIC)
	PHP_FE_END
};

static PHP_GINIT_FUNCTION(zprobe)
{
#if defined(COMPILE_DL_ZPROBE) && defined(ZTS)
	ZEND_TSRMLS_CACHE_UPDATE();
#endif
	memset(zprobe_globals, 0, sizeof(*zprobe_globals));
}

PHP_MINIT_FUNCTION(zprobe)
{
	zend_class_entry ce;
	REGISTER_INI_ENTRIES();
	INIT_NS_CLASS_ENTRY(ce, "ZProbe", "Point", point_methods);
	zprobe_point_ce = zend_register_internal_class(&ce);
	zprobe_point_ce->create_object = point_create;
	zend_declare_property_double(zprobe_point_ce, "x", 1, 0, ZEND_ACC_PUBLIC);
	zend_declare_property_double(zprobe_point_ce, "y", 1, 0, ZEND_ACC_PUBLIC);
	memcpy(&zprobe_point_handlers, zend_get_std_object_handlers(), sizeof(zend_object_handlers));
	zprobe_point_handlers.offset = XtOffsetOf(zprobe_point, std);
	zprobe_point_handlers.free_obj = point_free;
	REGISTER_LONG_CONSTANT("ZPROBE_ANSWER", 42, CONST_PERSISTENT);
	return SUCCESS;
}

PHP_MSHUTDOWN_FUNCTION(zprobe)
{
	UNREGISTER_INI_ENTRIES();
	return SUCCESS;
}

PHP_RINIT_FUNCTION(zprobe)
{
#if defined(ZTS) && defined(COMPILE_DL_ZPROBE)
	ZEND_TSRMLS_CACHE_UPDATE();
#endif
	return SUCCESS;
}

PHP_MINFO_FUNCTION(zprobe)
{
	php_info_print_table_start();
	php_info_print_table_row(2, "zprobe support", "enabled");
	php_info_print_table_end();
	DISPLAY_INI_ENTRIES();
}

zend_module_entry zprobe_module_entry = {
	STANDARD_MODULE_HEADER,
	"zprobe",
	zprobe_functions,
	PHP_MINIT(zprobe),
	PHP_MSHUTDOWN(zprobe),
	PHP_RINIT(zprobe),
	NULL,
	PHP_MINFO(zprobe),
	"0.1",
	PHP_MODULE_GLOBALS(zprobe),
	PHP_GINIT(zprobe),
	NULL,
	NULL,
	STANDARD_MODULE_PROPERTIES_EX
};

#ifdef COMPILE_DL_ZPROBE
ZEND_GET_MODULE(zprobe)
#endif
