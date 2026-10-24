/*
 * pg-server: runs PostgreSQL's server in the foreground for zigsaw, making
 * its cluster first if there isn't one.
 *
 *   postgresql [postgres options]      e.g. postgresql -p 5433
 *
 * The cluster is in PGDATA (the app's data, by the image's env). The first
 * run makes it with initdb: UTF-8, the builtin provider's C.UTF-8 (which no
 * Windows update changes, as it would ICU's or Windows' own collations),
 * PostgreSQL's default max_connections and shared_buffers, and scram-sha-256
 * for every connection, as superuser postgres with a random password. The password goes in PGPASSFILE, where the app's own clients
 * (psql, pg_dump, ...) find it; anyone else needs it from there.
 *
 * A run's job object ends whatever the run leaves behind, so the server
 * stays in the foreground, as long as the run: pg_ctl start would end with
 * its own run. Ctrl+C reaches postgres, which shuts down fast; this waits.
 *
 * postgres refuses to run as an administrator. As initdb and pg_ctl do,
 * this runs itself again with Administrators and Power Users deny-only first
 * (get_restricted_token), and its children inherit that.
 *
 * Paths are in the ANSI code page, as PostgreSQL's own programs take them.
 */

#include "postgres_fe.h"

#include <bcrypt.h>

#include "common/logging.h"
#include "common/restricted_token.h"

static BOOL WINAPI
ignore_console_event(DWORD event)
{
	(void) event;
	return TRUE;
}

/* The rest of this process's command line, after the program's name. */
static const char *
arguments(void)
{
	const char *p = GetCommandLineA();

	/* argv[0] as CommandLineToArgvW reads it: quoted, or to a space. */
	if (*p == '"')
	{
		p++;
		while (*p && *p != '"')
			p++;
		if (*p)
			p++;
	}
	else
		while (*p && *p != ' ' && *p != '\t')
			p++;
	while (*p == ' ' || *p == '\t')
		p++;
	return p;
}

/* Runs a command line and returns its exit code, or -1. */
static int
run(const char *cmdline)
{
	STARTUPINFOA si = {sizeof(si)};
	PROCESS_INFORMATION pi;
	DWORD		code;
	char	   *copy = strdup(cmdline);

	if (!copy || !CreateProcessA(NULL, copy, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi))
	{
		pg_log_error("could not start %s: error code %lu", cmdline, GetLastError());
		free(copy);
		return -1;
	}
	free(copy);
	CloseHandle(pi.hThread);
	WaitForSingleObject(pi.hProcess, INFINITE);
	if (!GetExitCodeProcess(pi.hProcess, &code))
		code = (DWORD) -1;
	CloseHandle(pi.hProcess);
	return (int) code;
}

/* Writes text to a new file. */
static bool
write_new(const char *path, const char *text)
{
	HANDLE		h = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
	DWORD		written;
	bool		ok;

	if (h == INVALID_HANDLE_VALUE)
	{
		pg_log_error("could not create \"%s\": error code %lu", path, GetLastError());
		return false;
	}
	ok = WriteFile(h, text, (DWORD) strlen(text), &written, NULL) && written == strlen(text);
	CloseHandle(h);
	if (!ok)
		pg_log_error("could not write \"%s\": error code %lu", path, GetLastError());
	return ok;
}

/* Makes the cluster in pgdata, saving its password in pgpass. */
static bool
make_cluster(const char *bindir, const char *pgdata, const char *pgpass)
{
	static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
	unsigned char bytes[24];
	char		password[sizeof(bytes) + 2];
	char		line[sizeof(password) + 32];
	char		pwfile[MAXPGPATH + 16];
	char		cmdline[3 * MAXPGPATH + 512];
	int			code;

	if (!BCRYPT_SUCCESS(BCryptGenRandom(NULL, bytes, sizeof(bytes), BCRYPT_USE_SYSTEM_PREFERRED_RNG)))
	{
		pg_log_error("could not make a password");
		return false;
	}
	for (size_t i = 0; i < sizeof(bytes); i++)
		password[i] = alphabet[bytes[i] % (sizeof(alphabet) - 1)];
	password[sizeof(bytes)] = '\n';
	password[sizeof(bytes) + 1] = '\0';

	snprintf(pwfile, sizeof(pwfile), "%s.initdb-pw", pgdata);
	DeleteFileA(pwfile);
	if (!write_new(pwfile, password))
		return false;

	/*
	 * initdb would make the directory after each of its parents it can't
	 * stat, and an AppContainer can't stat the store's: it gets one.
	 */
	if (!CreateDirectoryA(pgdata, NULL) && GetLastError() != ERROR_ALREADY_EXISTS)
	{
		pg_log_error("could not create \"%s\": error code %lu", pgdata, GetLastError());
		DeleteFileA(pwfile);
		return false;
	}

	/*
	 * initdb picks max_connections and shared_buffers by running postgres
	 * through cmd.exe (system()), which in an AppContainer can't start a
	 * program in the store, so it would take its least (20, 400kB): the
	 * server's own defaults are set instead.
	 */
	fprintf(stderr, "Making a database cluster in %s\n", pgdata);
	snprintf(cmdline, sizeof(cmdline),
			 "\"%s\\initdb.exe\" -D \"%s\" -U postgres -E UTF8 --locale=C"
			 " --locale-provider=builtin --builtin-locale=C.UTF-8"
			 " --auth=scram-sha-256 \"--pwfile=%s\" --no-instructions"
			 " -c max_connections=100 -c shared_buffers=128MB",
			 bindir, pgdata, pwfile);
	code = run(cmdline);
	DeleteFileA(pwfile);
	if (code != 0)
	{
		pg_log_error("initdb failed; remove \"%s\" to make the cluster again", pgdata);
		return false;
	}

	password[sizeof(bytes)] = '\0';
	snprintf(line, sizeof(line), "*:*:*:postgres:%s\n", password);
	DeleteFileA(pgpass);
	if (!write_new(pgpass, line))
		return false;
	fprintf(stderr, "The postgres user's password is in %s\n", pgpass);
	return true;
}

/* Whether postgres is asked only for its help, version or settings. */
static bool
informational(int argc, char **argv)
{
	for (int i = 1; i < argc; i++)
		if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-?") == 0 ||
			strcmp(argv[i], "--version") == 0 || strcmp(argv[i], "-V") == 0 ||
			strcmp(argv[i], "--describe-config") == 0)
			return true;
	return false;
}

int
main(int argc, char **argv)
{
	char		bindir[MAXPGPATH];
	char		pgdata[MAXPGPATH];
	char		pgpass[MAXPGPATH];
	char		version[MAXPGPATH + 16];
	char	   *slash;
	char	   *cmdline;
	const char *args;
	size_t		size;
	int			code;

	pg_logging_init(argv[0]);
	get_restricted_token();

	if (!GetModuleFileNameA(NULL, bindir, sizeof(bindir)) || !(slash = strrchr(bindir, '\\')))
		pg_fatal("could not find this program's directory");
	*slash = '\0';

	if (!informational(argc, argv))
	{
		if (!GetEnvironmentVariableA("PGDATA", pgdata, sizeof(pgdata)))
			pg_fatal("PGDATA isn't set");
		if (!GetEnvironmentVariableA("PGPASSFILE", pgpass, sizeof(pgpass)))
			pg_fatal("PGPASSFILE isn't set");
		snprintf(version, sizeof(version), "%s\\PG_VERSION", pgdata);
		if (GetFileAttributesA(version) == INVALID_FILE_ATTRIBUTES &&
			!make_cluster(bindir, pgdata, pgpass))
			return 1;
	}

	SetConsoleCtrlHandler(ignore_console_event, TRUE);
	args = arguments();
	size = strlen(bindir) + strlen(args) + 32;
	cmdline = malloc(size);
	if (!cmdline)
		pg_fatal("out of memory");
	snprintf(cmdline, size, "\"%s\\postgres.exe\" %s", bindir, args);
	code = run(cmdline);
	free(cmdline);
	return code < 0 ? 1 : code;
}
