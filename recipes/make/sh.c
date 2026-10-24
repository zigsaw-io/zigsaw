/* sh for GNU make: make on Windows runs recipes in sh.exe when it finds one
 * on PATH, and in cmd.exe when it doesn't. BusyBox's image has busybox.exe
 * and no sh.exe, so this one runs `busybox.exe sh` with the rest of its own
 * command line, as it was given, and exits with the shell's exit code.
 *
 * Ctrl+C reaches the shell through the console they share, so this one
 * ignores it and waits; the shell is in a job that ends with this process,
 * so make stopping a recipe (TerminateProcess) stops its shell too. */
#include <stdio.h>
#include <wchar.h>
#include <windows.h>

/* The command line after the program's name, which the C runtime splits off
 * as argv[0]: up to the closing quote if it starts with one, else up to the
 * first blank. */
static const wchar_t *after_program(const wchar_t *line) {
    if (*line == L'"') {
        line++;
        while (*line && *line != L'"') line++;
        if (*line) line++;
    } else {
        while (*line && *line != L' ' && *line != L'\t') line++;
    }
    while (*line == L' ' || *line == L'\t') line++;
    return line;
}

int wmain(void) {
    wchar_t busybox[MAX_PATH];
    DWORD found = SearchPathW(NULL, L"busybox.exe", NULL, MAX_PATH, busybox, NULL);
    if (found == 0 || found >= MAX_PATH) {
        fwprintf(stderr, L"sh: busybox.exe isn't on PATH\n");
        return 127;
    }

    const wchar_t *args = after_program(GetCommandLineW());
    size_t size = wcslen(busybox) + wcslen(args) + 8;
    wchar_t *line = HeapAlloc(GetProcessHeap(), 0, size * sizeof *line);
    if (!line) return 1;
    swprintf(line, size, L"\"%ls\" sh %ls", busybox, args);

    HANDLE job = CreateJobObjectW(NULL, NULL);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = { 0 };
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!job || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof limits)) {
        fwprintf(stderr, L"sh: could not make a job: error %lu\n", GetLastError());
        return 1;
    }

    SetConsoleCtrlHandler(NULL, TRUE);
    STARTUPINFOW si = { .cb = sizeof si };
    PROCESS_INFORMATION pi;
    if (!CreateProcessW(busybox, line, NULL, NULL, TRUE, CREATE_SUSPENDED, NULL, NULL, &si, &pi)) {
        fwprintf(stderr, L"sh: could not start %ls: error %lu\n", busybox, GetLastError());
        return 127;
    }
    if (!AssignProcessToJobObject(job, pi.hProcess)) {
        fwprintf(stderr, L"sh: could not put the shell in a job: error %lu\n", GetLastError());
        TerminateProcess(pi.hProcess, 1);
        return 1;
    }
    ResumeThread(pi.hThread);
    WaitForSingleObject(pi.hProcess, INFINITE);

    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    return (int)code;
}
