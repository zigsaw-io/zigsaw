/* windres for builds with GTK's SDK: GNU windres's command line, for zig's
 * resource compiler. Rust's winresource and embed-resource crates, and
 * libtool, run windres as
 *
 *   windres [-D...] [-I<dir>] [--target pe-x86-64] [-i] <in.rc> [-o] <out.o>
 *           [--output-format=coff]
 *
 * zig's rc takes the input and output as plain arguments and the -D and -I
 * options as they are; it writes a COFF object, which GNU ld and lld link,
 * with /:output-format coff, and includes zig's MinGW headers, rather than
 * Visual Studio's when the machine has them, with /:auto-includes gnu. zig
 * is on PATH wherever the SDK is, as one of its runtimes. */
#include <errno.h>
#include <process.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/* Quotes an argument for the command line CreateProcess hands to the
 * program, as its C runtime splits it again (backslashes before a quote
 * doubled). */
static wchar_t *quote(const wchar_t *arg) {
    size_t len = wcslen(arg);
    wchar_t *out = malloc((2 * len + 3) * sizeof *out);
    wchar_t *o = out;
    if (!out) exit(1);
    if (len && !wcspbrk(arg, L" \t\n\v\"")) {
        wcscpy(out, arg);
        return out;
    }
    *o++ = L'"';
    for (const wchar_t *p = arg;; p++) {
        size_t backslashes = 0;
        while (*p == L'\\') { p++; backslashes++; }
        if (!*p) {
            for (size_t i = 0; i < 2 * backslashes; i++) *o++ = L'\\';
            break;
        }
        if (*p == L'"') backslashes = 2 * backslashes + 1;
        for (size_t i = 0; i < backslashes; i++) *o++ = L'\\';
        *o++ = *p;
    }
    *o++ = L'"';
    *o = 0;
    return out;
}

int wmain(int argc, wchar_t **argv) {
    static const wchar_t *const lead[] = { L"zig", L"rc", L"/:auto-includes", L"gnu", L"/:output-format", L"coff" };
    const size_t nlead = sizeof lead / sizeof *lead;
    const wchar_t **args = calloc(nlead + (size_t)argc + 1, sizeof *args);
    size_t n = 0;
    if (!args) return 1;
    for (size_t i = 0; i < nlead; i++) args[n++] = quote(lead[i]);
    for (int i = 1; i < argc; i++) {
        const wchar_t *a = argv[i];
        if (!wcscmp(a, L"-i") || !wcscmp(a, L"--input") || !wcscmp(a, L"-o") || !wcscmp(a, L"--output"))
            continue;
        if (!wcscmp(a, L"--output-format=coff") || !wcscmp(a, L"-O"))
            continue;
        if (!wcscmp(a, L"coff") && i > 1 && !wcscmp(argv[i - 1], L"-O"))
            continue;
        if (!wcscmp(a, L"--target") || !wcscmp(a, L"-F")) {
            i++; /* and its BFD name, pe-x86-64: zig's rc writes x64 */
            continue;
        }
        if (!wcsncmp(a, L"--target=", 9))
            continue;
        args[n++] = quote(a);
    }
    args[n] = NULL;
    fflush(NULL);
    intptr_t status = _wspawnvp(_P_WAIT, L"zig", args);
    if (status == -1) {
        fwprintf(stderr, L"windres: can't run zig: %hs\n", strerror(errno));
        return 127;
    }
    return (int)status;
}
