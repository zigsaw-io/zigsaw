/* <unicode/uloc.h> for libspelling, from Windows' own ICU (icu.dll, in
 * Windows 10 1903 and later), which zig links as -licu but has no header
 * for: the two functions libspelling uses, to name a dictionary's language
 * in the user's. */
#ifndef ZIGSAW_ULOC_H
#define ZIGSAW_ULOC_H

#include <stdint.h>

typedef uint16_t UChar;
typedef enum UErrorCode { U_ZERO_ERROR = 0 } UErrorCode;
#define U_SUCCESS(x) ((x) <= U_ZERO_ERROR)

int32_t uloc_getDisplayName(const char *localeID, const char *inLocaleID, UChar *result, int32_t maxResultSize, UErrorCode *err);
int32_t uloc_getDisplayLanguage(const char *locale, const char *displayLocale, UChar *language, int32_t languageCapacity, UErrorCode *status);

#endif
