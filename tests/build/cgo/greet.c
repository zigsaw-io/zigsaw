#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include "greet.h"

/* A greeting the caller frees. */
char *greet(const char *who) {
    size_t n = strlen(who) + 32;
    char *s = malloc(n);
    snprintf(s, n, "hello, %s, from Go and C", who);
    return s;
}

unsigned long process_id(void) {
    return GetCurrentProcessId();
}
