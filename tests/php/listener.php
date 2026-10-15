<?php
// A DBGp client, as an IDE is to Xdebug: listens on 127.0.0.1:<port>, takes
// one connection, prints the <init> packet's language, tells Xdebug to run,
// and prints the status of its last response. Gives up after <seconds>.
//
//   php listener.php <port> <seconds>

[, $port, $seconds] = $argv + [null, '9003', '20'];
$server = stream_socket_server("tcp://127.0.0.1:$port", $errno, $errstr);
if (!$server) {
    echo "can't listen on $port: $errstr\n";
    exit(1);
}
echo "listening\n";
$conn = @stream_socket_accept($server, (float) $seconds);
if (!$conn) {
    echo "no connection\n";
    exit(2);
}
stream_set_timeout($conn, (int) $seconds);

// A DBGp packet: its length, NUL, the XML, NUL.
function packet($conn): ?string
{
    $len = stream_get_line($conn, 32, "\0");
    if ($len === false || $len === '') return null;
    $xml = stream_get_contents($conn, (int) $len + 1);
    return $xml === false ? null : rtrim($xml, "\0");
}

$init = packet($conn);
echo preg_match('/<init [^>]*language="([^"]*)"/', (string) $init, $m) ? "init {$m[1]}\n" : "no init\n";
fwrite($conn, "run -i 1\0");
$last = null;
while (($p = packet($conn)) !== null) $last = $p;
echo preg_match('/status="([^"]*)"/', (string) $last, $m) ? "status {$m[1]}\n" : "no status\n";
