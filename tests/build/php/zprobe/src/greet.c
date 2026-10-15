/* In a subdirectory, which config.w32 adds with ADD_SOURCES; it calls
 * version.dll, whose import library config.w32 finds with CHECK_LIB. */
#include <windows.h>
#include "greet.h"

unsigned long zprobe_version_info_size(void)
{
#ifdef HAVE_ZPROBE_VERSION_LIB
	return GetFileVersionInfoSizeW(L"kernel32.dll", NULL);
#else
	return 0;
#endif
}
