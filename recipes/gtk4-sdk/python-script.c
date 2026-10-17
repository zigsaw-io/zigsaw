/* A program for a Python script of GTK's SDK: g-ir-scanner.exe runs the
 * script g-ir-scanner beside it with the SDK's Python, python\python.exe
 * next to bin, and the arguments it was given.
 *
 * gobject-introspection installs its scripts with the Python it was built
 * with in their #! line, B:\prefix\python\python.exe, which is only there
 * while the SDK builds; Meson runs scripts by that line, and builds and
 * runs with the SDK see it where the store deployed it. GI's pkg-config
 * file names these programs instead. */
#include <errno.h>
#include <process.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <windows.h>

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
    wchar_t self[32768], python[32768];
    DWORD len = GetModuleFileNameW(NULL, self, sizeof self / sizeof *self);
    if (!len || len >= sizeof self / sizeof *self) {
        fwprintf(stderr, L"can't find this program's own path\n");
        return 127;
    }
    /* The script: this program's path without ".exe". */
    if (len > 4 && !_wcsicmp(self + len - 4, L".exe")) self[len - 4] = 0;
    /* The Python: ..\python\python.exe from this program's directory. */
    wcscpy(python, self);
    wchar_t *slash = wcsrchr(python, L'\\');
    if (!slash) return 127;
    *slash = 0;
    slash = wcsrchr(python, L'\\');
    if (!slash) return 127;
    wcscpy(slash, L"\\python\\python.exe");

    const wchar_t **args = calloc((size_t)argc + 2, sizeof *args);
    size_t n = 0;
    if (!args) return 1;
    args[n++] = quote(python);
    args[n++] = quote(self);
    for (int i = 1; i < argc; i++) args[n++] = quote(argv[i]);
    args[n] = NULL;
    fflush(NULL);
    intptr_t status = _wspawnv(_P_WAIT, python, args);
    if (status == -1) {
        fwprintf(stderr, L"can't run %ls: %hs\n", python, strerror(errno));
        return 127;
    }
    return (int)status;
}
