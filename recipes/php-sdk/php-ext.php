<?php
// php-ext: builds a PHP extension from its sources with zig, as phpize,
// configure and nmake build it with MSVC, for this SDK's PHP.
//
//   php-ext build [--enable-foo[=...]|--with-foo[=...]|--disable-foo|--without-foo]... [--out DIR] [-j N]
//   php-ext test <tests dir or .phpt>... --ext DLL [--ext DLL]... [--runner FILE] [-j N] [-- run-tests.php options]
//
// build runs in the extension's directory, where its config.w32 is. Node
// runs config.w32 (config-w32.js), which says what to compile; zig's cc
// compiles and links it against PHP's import library, with zig-php.h and
// zig-php.c, which let clang build what MSVC builds of PHP load. It writes
// php_<ext>.dll, conf.d\<ext>.ini and about.bat into --out: $PREFIX in a
// build, the extension's directory otherwise. The .ini loads the DLL from
// the directory ${PHP_EXT_<EXT>} names, which an extension image's env
// sets to ${app}. For extensions that build with this one, it also writes
// the DLL's import library into lib\ and the headers config.w32 installs
// into include\; extensions whose PHP_EXT_<EXT> names such a directory, as
// their images do as SDKs of a recipe, can depend on it (ADD_EXTENSION_DEP).
// The headers and import libraries of the libraries PHP's build is linked
// with (deps\, from php.net's deps packages) are where config.w32 looks.
//
// test runs PHP's run-tests.php with this SDK's php.exe and the given
// extensions, in parallel, then again one at a time for the tests that
// failed, since tests that open sockets fail when many run at once.

declare(strict_types=1);

const DEFAULT_LIBS = ['kernel32', 'ole32', 'user32', 'advapi32', 'shell32', 'ws2_32', 'dnsapi', 'psapi', 'bcrypt', 'pathcch'];

$dev = dirname(__DIR__);
$args = array_slice($argv, 1);
$command = array_shift($args);
try {
    exit(match ($command) {
        'build' => build($dev, $args),
        'test' => test($dev, $args),
        default => usage(),
    });
} catch (RuntimeException $e) {
    fwrite(STDERR, 'php-ext: ' . $e->getMessage() . "\n");
    exit(1);
}

function usage(): int
{
    fwrite(STDERR, "usage: php-ext build [--enable-foo|--with-foo[=...]]... [--out DIR] [-j N]\n"
        . "       php-ext test <tests>... --ext DLL... [--runner FILE] [-j N] [-- run-tests.php options]\n");
    return 2;
}

function jobs(): int
{
    return max(1, (int) (getenv('NUMBER_OF_PROCESSORS') ?: 4));
}

// --- build ----------------------------------------------------------------

function build(string $dev, array $args): int
{
    $out = getenv('PREFIX') ?: getcwd();
    $jobs = jobs();
    $configure = [];
    for ($i = 0; $i < count($args); $i++) {
        $a = $args[$i];
        if ($a === '--out' || $a === '-j') {
            $v = $args[++$i] ?? throw new RuntimeException("$a needs a value");
            if ($a === '--out') $out = $v; else $jobs = max(1, (int) $v);
        } elseif (str_starts_with($a, '--out=')) {
            $out = substr($a, 6);
        } else {
            $configure[] = $a;
        }
    }
    $src = getcwd();
    if (!is_file("$src/config.w32")) throw new RuntimeException("no config.w32 in $src");

    [$systemLibs, $systemInclude] = zigLibc();
    $config = configure($dev, $src, $configure, $systemLibs, $systemInclude);

    $tmp = "$src/php-ext-build";
    removeTree($tmp);
    mkdir("$tmp/main", 0777, true);
    // AC_DEFINEs: phpize writes them into main/config.pickle.h, which PHP's
    // config.w32.h includes when there is one. This one is the build's own,
    // found first on the include path, so the SDK stays as it is.
    $pickle = "/* Written by php-ext from config.w32's AC_DEFINEs. */\n";
    foreach ($config['defines'] as $name => $value) $pickle .= "#define $name $value\n";
    file_put_contents("$tmp/main/config.pickle.h", $pickle);

    $flags = $config['flags'];
    $prefix = (string) getenv('PREFIX');
    $base = array_merge(
        // Calling an undeclared function is a warning for MSVC (C4013), and
        // extensions do, as redis does PHP's usleep and gettimeofday.
        ['-O2', '-fms-extensions', '-Wno-date-time', '-Wno-error=implicit-function-declaration',
         '-include', "$dev/zigsaw/zig-php.h", "-I$tmp", '-I.'],
        array_map(fn($d) => "-I$dev/include$d", ['', '/main', '/Zend', '/TSRM', '/ext']),
        // The headers of libraries the recipe built first, in the build's
        // prefix, then of those PHP's build links with, which its configure
        // puts on every compile's include path too.
        $prefix !== '' && is_dir("$prefix/include") ? ["-I$prefix/include"] : [],
        is_dir("$dev/deps/include") ? ["-I$dev/deps/include"] : [],
        ['-D_WINDOWS', '-DWINDOWS=1', '-DZEND_WIN32=1', '-DPHP_WIN32=1', '-DWIN32', '-D_MBCS', '-D_USE_MATH_DEFINES',
         '-DNDebug', '-DNDEBUG', '-DZEND_DEBUG=0'],
        msvcFlags($flags['CFLAGS'] ?? ''),
    );
    if (!is_dir($out)) mkdir($out, 0777, true);
    $built = 0;
    foreach ($config['extensions'] as $ext) {
        $name = $ext['name'];
        $EXT = strtoupper($name);
        $cflags = array_merge($base, msvcFlags($flags["CFLAGS_$EXT"] ?? ''));
        $compiles = [];
        foreach ($config['sources'] as $s) {
            if ($s['target'] !== strtolower($name)) continue;
            $obj = "$tmp/" . str_replace(['/', '\\', '.'], '_', ltrim($s['file'], './')) . '.o';
            $compiles[] = [$s['file'], array_merge(['cc'], $cflags, ['-c', $s['file'], '-o', $obj]), $obj];
        }
        $compiles[] = ['zig-php.c', array_merge(['cc'], $base, ['-c', "$dev/zigsaw/zig-php.c", '-o', "$tmp/zig-php.o"]), "$tmp/zig-php.o"];
        runAll($compiles, $jobs);

        $libs = [];
        foreach (preg_split('/\s+/', trim(($flags['LIBS'] ?? '') . ' ' . ($flags["LIBS_$EXT"] ?? '')), -1, PREG_SPLIT_NO_EMPTY) as $lib)
            $libs[] = libArg($dev, $lib);
        foreach (DEFAULT_LIBS as $lib) if (isset($systemLibs[$lib])) $libs[] = "-l$lib";
        $ldflags = array_merge(
            preg_split('/\s+/', trim((string) getenv('LDFLAGS')), -1, PREG_SPLIT_NO_EMPTY),
            linkFlags(($flags['LDFLAGS'] ?? '') . ' ' . ($flags["LDFLAGS_$EXT"] ?? '')),
        );
        $dll = "$out/{$ext['dll']}";
        // The import library goes in lib\, for extensions that link with
        // this one (zig writes it next to the DLL otherwise, named after the
        // first object).
        if (!is_dir("$out/lib")) mkdir("$out/lib");
        $implib = "-Wl,--out-implib,$out/lib/" . preg_replace('/\.dll$/i', '.lib', $ext['dll']);
        run(array_merge(['cc', '-shared', '-o', $dll], array_column($compiles, 2), ["$dev/lib/php8.lib"], array_unique($libs), $ldflags, [$implib]));

        // The .ini and about.bat an extension image carries.
        $directive = $ext['zend'] ? 'zend_extension' : 'extension';
        if (!is_dir("$out/conf.d")) mkdir("$out/conf.d");
        file_put_contents("$out/conf.d/$name.ini",
            "; $name, built by php-ext. PHP_EXT_$EXT names the directory php_$name.dll is in.\n"
            . "$directive=\"\${PHP_EXT_$EXT}\\{$ext['dll']}\"\n");
        $php = PHP_VERSION;
        preg_match('/#define ZEND_MODULE_API_NO (\d+)/', (string) file_get_contents("$dev/include/Zend/zend_modules.h"), $m);
        $api = $m[1] ?? '?';
        file_put_contents("$out/about.bat", implode("\r\n", [
            '@echo off',
            "echo This image is the PHP extension $name, for PHP $php (NTS, x64, API $api).",
            "echo Installed, it joins every run of PHP, and of apps that have PHP as a runtime;",
            "echo zigsaw run --noextension=^<its id^> leaves it out.",
            '',
        ]));
        fwrite(STDOUT, "php-ext: built $dll\n");
        $built++;
    }
    // The headers config.w32 installs, for extensions that build with this one.
    foreach ($config['headers'] as $h) {
        $dest = "$out/include/{$h['dest']}";
        if (!is_dir(dirname($dest))) mkdir(dirname($dest), 0777, true);
        copy($h['file'], $dest) || throw new RuntimeException("can't copy {$h['file']}");
    }
    removeTree($tmp);
    return $built > 0 ? 0 : 1;
}

// The MinGW import libraries zig has (by name, lower case), and its headers'
// directory: config.w32's CHECK_LIB and CHECK_HEADER_ADD_INCLUDE look there
// for Windows' own.
function zigLibc(): array
{
    $env = capture(['zig', 'env']);
    if (!preg_match('/\.lib_dir = "((?:[^"\\\\]|\\\\.)*)"/', $env, $m)) throw new RuntimeException("can't find zig's lib directory in `zig env`");
    $lib = stripcslashes($m[1]) . '/libc';
    $libs = [];
    foreach (['mingw/lib-common', 'mingw/lib64'] as $dir)
        foreach (glob("$lib/$dir/*.def*") ?: [] as $f)
            $libs[strtolower(preg_replace('/\.def(\.in)?$/i', '', basename($f)))] = true;
    return [$libs, "$lib/include/any-windows-any"];
}

function configure(string $dev, string $src, array $args, array $systemLibs, string $systemInclude): array
{
    $env = getenv();
    $env['PHP_EXT_SYSTEM_LIBS'] = implode(';', array_keys($systemLibs));
    $env['PHP_EXT_SYSTEM_INCLUDE'] = $systemInclude;
    $json = capture(array_merge(['node', __DIR__ . '/config-w32.js', $src, $dev], $args), $env);
    $config = json_decode($json, true);
    if (!is_array($config)) throw new RuntimeException("config-w32.js printed no JSON");
    return $config;
}

// MSVC compiler flags as zig's cc takes them: /D, /I, /U and /FI have the
// same meaning; the rest are MSVC's own (warnings, optimization, code
// generation), and zig's defaults stand for them.
function msvcFlags(string $flags): array
{
    static $dropped = [];
    $out = [];
    $tokens = tokens($flags);
    for ($i = 0; $i < count($tokens); $i++) {
        $t = $tokens[$i];
        if (preg_match('#^[/-](D|I|U|FI)(.*)$#s', $t, $m)) {
            $v = $m[2] !== '' ? $m[2] : ($tokens[++$i] ?? '');
            $out[] = match ($m[1]) { 'FI' => '-include', default => '-' . $m[1] . $v };
            if ($m[1] === 'FI') $out[] = $v;
        } elseif (preg_match('#^-[Wfm]#', $t)) {
            $out[] = $t; // clang-cl's and GCC's spelling are the same here
        } else {
            if (!isset($dropped[$t])) fwrite(STDERR, "php-ext: leaving out the MSVC flag $t\n");
            $dropped[$t] = true;
        }
    }
    return $out;
}

function linkFlags(string $flags): array
{
    $out = [];
    foreach (tokens($flags) as $t) {
        if (preg_match('#^/libpath:(.*)$#i', $t, $m)) $out[] = '-L' . $m[1];
        elseif ($t !== '') fwrite(STDERR, "php-ext: leaving out the MSVC linker flag $t\n");
    }
    return $out;
}

// A library config.w32 names: one of PHP's own (php_foo.lib, in the devel
// pack), one the recipe built (in the build's prefix), one PHP's build links
// with (in deps), a file in a directory /libpath gave, or one of Windows'.
function libArg(string $dev, string $lib): string
{
    $prefix = (string) getenv('PREFIX');
    $dirs = array_merge(["$dev/lib"], $prefix !== '' ? ["$prefix/lib"] : [], ["$dev/deps/lib"]);
    foreach ($dirs as $d) if (is_file("$d/$lib")) return "$d/$lib";
    return '-l' . preg_replace('/\.lib$/i', '', $lib);
}

// Splits flags as the command line would, keeping "quoted values" whole.
function tokens(string $flags): array
{
    preg_match_all('/"([^"]*)"|(\S+)/', $flags, $m, PREG_SET_ORDER);
    // A quoted token is its contents, an unquoted one itself.
    return array_map(fn($t) => isset($t[2]) && $t[2] !== '' ? $t[2] : $t[1], $m);
}

// --- test -----------------------------------------------------------------

function test(string $dev, array $args): int
{
    $exts = [];
    $jobs = jobs();
    $tests = [];
    $pass = [];
    $runner = null;
    for ($i = 0; $i < count($args); $i++) {
        $a = $args[$i];
        if ($a === '--ext') {
            $exts[] = $args[++$i] ?? throw new RuntimeException('--ext needs a DLL');
        } elseif ($a === '--runner') {
            $runner = $args[++$i] ?? throw new RuntimeException('--runner needs a file');
        } elseif ($a === '-j') {
            $jobs = max(1, (int) ($args[++$i] ?? 1));
        } elseif ($a === '--') {
            $pass = array_slice($args, $i + 1);
            break;
        } elseif ($a[0] === '-') {
            throw new RuntimeException("unknown option $a (run-tests.php's go after --)");
        } else {
            // run-tests.php runs nothing, and passes, for a path that isn't there.
            if (!file_exists($a)) throw new RuntimeException("$a doesn't exist");
            $tests[] = $a;
        }
    }
    if (!$exts) throw new RuntimeException('test needs --ext <php_foo.dll>');
    if (!$tests) throw new RuntimeException('test needs the tests to run: a directory or .phpt files');
    $pass = array_merge($pass, $tests);
    $php = PHP_BINARY;
    // Each DLL as extension or zend_extension, which PHP tells apart only by
    // trying: a Zend extension exports zend_extension_entry.
    $ini = ['-n'];
    foreach ($exts as $dll) {
        $dll = realpath($dll) ?: throw new RuntimeException("$dll doesn't exist");
        $zend = str_contains((string) file_get_contents($dll), 'zend_extension_entry');
        array_push($ini, '-d', ($zend ? 'zend_extension=' : 'extension=') . $dll);
    }
    // run-tests.php takes these from TEST_PHP_ARGS, as its own options, and
    // so do tests that start PHP themselves (APCu's server tests, Xdebug's
    // debugger client). It splits the variable at spaces.
    foreach ($ini as $a) if (str_contains($a, ' ')) throw new RuntimeException("run-tests.php can't take a path with a space: $a");
    $env = getenv();
    $env['TEST_PHP_ARGS'] = implode(' ', $ini);
    $env['TEST_PHP_EXECUTABLE'] = $php;
    // run-tests.php writes a file next to itself, which the SDK's directory
    // doesn't allow: it runs from a copy. An extension's own (--runner), as
    // Xdebug has run-xdebug-tests.php, runs where it is, in its sources.
    $work = sys_get_temp_dir() . '/php-ext-test-' . getmypid();
    removeTree($work);
    mkdir($work);
    if ($runner === null) {
        $runner = "$work/run-tests.php";
        copy("$dev/script/run-tests.php", $runner);
    } elseif (!is_file($runner)) {
        throw new RuntimeException("$runner doesn't exist");
    }
    $failed = "$work/failed.txt";
    $runTests = [$php, '-n', $runner, '-q', '-p', $php];
    $code = run(array_merge($runTests, ["-j$jobs", '-w', $failed], $pass), $env, true);
    $first = is_file($failed) ? array_filter(array_map('trim', file($failed))) : [];
    if ($code !== 0 && !$first) {
        removeTree($work);
        throw new RuntimeException("run-tests.php exited with $code");
    }
    if ($first) {
        fwrite(STDOUT, "php-ext: running the " . count($first) . " failed tests again, one at a time\n");
        run(array_merge($runTests, ['-r', $failed, '-w', $failed]), $env, true);
    }
    $still = array_filter(array_map('trim', file($failed) ?: []));
    removeTree($work);
    fwrite(STDOUT, "php-ext: " . count($still) . " tests failed" . ($still ? ":\n" . implode("\n", $still) : '') . "\n");
    return $still ? 1 : 0;
}

// --- processes ------------------------------------------------------------

function run(array $cmd, ?array $env = null, bool $mayFail = false): int
{
    $p = proc_open($cmd, [0 => ['file', 'NUL', 'r'], 1 => STDOUT, 2 => STDERR], $pipes, null, $env, ['bypass_shell' => true]);
    if (!is_resource($p)) throw new RuntimeException("can't run {$cmd[0]}");
    $code = proc_close($p);
    if ($code !== 0 && !$mayFail) throw new RuntimeException("{$cmd[0]} exited with $code");
    return $code;
}

function capture(array $cmd, ?array $env = null): string
{
    $p = proc_open($cmd, [0 => ['file', 'NUL', 'r'], 1 => ['pipe', 'w'], 2 => STDERR], $pipes, null, $env, ['bypass_shell' => true]);
    if (!is_resource($p)) throw new RuntimeException("can't run {$cmd[0]}");
    $out = stream_get_contents($pipes[1]);
    fclose($pipes[1]);
    $code = proc_close($p);
    if ($code !== 0) throw new RuntimeException("{$cmd[0]} exited with $code");
    return $out;
}

// Runs [label, command, output] compiles, $jobs at a time; prints the
// compiler's messages for each, and fails after all have run if any failed.
// Their output goes to files: PHP can't read pipes without blocking on
// Windows, and a compiler that fills one pipe while PHP waits on the other
// would never finish.
function runAll(array $compiles, int $jobs): void
{
    $running = [];
    $failed = [];
    $queue = $compiles;
    while ($queue || $running) {
        while ($queue && count($running) < $jobs) {
            [$label, $cmd, $obj] = array_shift($queue);
            $log = "$obj.log";
            $p = proc_open($cmd, [0 => ['file', 'NUL', 'r'], 1 => ['file', $log, 'w'], 2 => ['file', $log, 'a']], $pipes, null, null, ['bypass_shell' => true]);
            if (!is_resource($p)) throw new RuntimeException("can't run {$cmd[0]}");
            $running[] = [$label, $p, $log];
        }
        foreach ($running as $k => [$label, $p, $log]) {
            $status = proc_get_status($p);
            if ($status['running']) continue;
            proc_close($p);
            $messages = (string) @file_get_contents($log);
            if ($messages !== '') fwrite(STDERR, $messages);
            if ($status['exitcode'] !== 0) $failed[] = $label;
            unset($running[$k]);
        }
        if ($running) usleep(20000);
    }
    if ($failed) throw new RuntimeException('failed to compile ' . implode(', ', $failed));
}

function removeTree(string $dir): void
{
    if (!is_dir($dir)) return;
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST);
    foreach ($it as $f) $f->isDir() && !$f->isLink() ? rmdir($f->getPathname()) : unlink($f->getPathname());
    rmdir($dir);
}
