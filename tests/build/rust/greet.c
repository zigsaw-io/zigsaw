#include <stdio.h>
#include <stdlib.h>

/* stdio and stdlib, from zig's C headers, linked with Rust's C runtime. */
int greet_c(char *buf, size_t len, const char *name) {
    if (getenv("GREET_DEBUG")) fprintf(stderr, "greet_c(%s)\n", name);
    return snprintf(buf, len, "hello from C, %s (%ld)", name, strtol("42", NULL, 10));
}
