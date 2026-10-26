<?php
// serve.php: Kanboard's kanboard command. It serves Kanboard with PHP's
// built-in web server where KANBOARD_LISTEN says, or --listen, and opens it
// in the default browser unless --no-browser, at KANBOARD_URL. Those are
// the app's service, http (see recipes/kanboard.json): 127.0.0.1:8471, or
// where zigsaw publishes it from inside an AppContainer. Kanboard keeps its
// database and files where DATA_DIR says: the app's data directory. Ctrl+C,
// or closing the window, stops it.
//
//   kanboard [--listen=<host>:<port>] [--no-browser]

declare(strict_types=1);

$listen = getenv('KANBOARD_LISTEN') ?: '127.0.0.1:8471';
$url = getenv('KANBOARD_URL') ?: null;
$browser = true;
foreach (array_slice($argv, 1) as $a) {
    if (str_starts_with($a, '--listen=')) {
        $listen = substr($a, strlen('--listen='));
        // Served there, rather than where zigsaw publishes it.
        $url = null;
    } elseif ($a === '--no-browser') {
        $browser = false;
    } else {
        fwrite(STDERR, "usage: kanboard [--listen=<host>:<port>] [--no-browser]\n");
        exit(2);
    }
}
if (!preg_match('/^(.+):(\d+)$/', $listen, $m)) {
    fwrite(STDERR, "kanboard: --listen takes <host>:<port>, such as 127.0.0.1:8471\n");
    exit(2);
}
[, $host, $port] = $m;

// The built-in server says a port is taken only after it says it started.
$probe = @stream_socket_server("tcp://$listen", $errno, $error);
if ($probe === false) {
    fwrite(STDERR, "kanboard: can't listen on $listen: $error\n");
    exit(1);
}
fclose($probe);

$server = proc_open(
    [PHP_BINARY, '-S', $listen, '-t', __DIR__ . '\\kanboard', __DIR__ . '\\router.php'],
    [STDIN, STDOUT, STDERR], $pipes, null, null, ['bypass_shell' => true]);
if (!is_resource($server)) {
    fwrite(STDERR, "kanboard: can't start PHP's web server\n");
    exit(1);
}
$url ??= 'http://' . ($host === '0.0.0.0' ? '127.0.0.1' : $host) . ":$port/";
fwrite(STDOUT, "Kanboard is at $url (the first time, log in as admin, password admin). Ctrl+C stops it.\n");
if ($browser) {
    // Once the server answers, Explorer opens the address in the default
    // browser, which then runs outside this app's sandbox: a browser started
    // from here would end with the server.
    for ($i = 0; $i < 50; $i++) {
        $c = @fsockopen($host === '0.0.0.0' ? '127.0.0.1' : $host, (int) $port, $errno, $error, 0.2);
        if ($c !== false) {
            fclose($c);
            break;
        }
        usleep(100000);
    }
    $explorer = proc_open([getenv('SystemRoot') . '\\explorer.exe', $url], [], $p, null, null, ['bypass_shell' => true]);
    if (is_resource($explorer)) proc_close($explorer);
}
exit(proc_close($server));
