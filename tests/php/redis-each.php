<?php
// redis-each.php <tests dir> <host> <port>: runs Redis_Test's methods as
// TestSuite::run does, but goes on after an Error (miniredis lacks some of
// what tests read, as INFO's sections), printing "<name> <RESULT>" per test.
[, $dir, $host, $port] = $argv;
define('PHPREDIS_TESTRUN', true);
require_once "$dir/TestSuite.php";
require_once "$dir/RedisTest.php";
TestSuite::flagColorization(false);
$counts = [];
foreach ((new ReflectionClass('Redis_Test'))->getMethods(ReflectionMethod::IS_PUBLIC) as $m) {
    $name = $m->name;
    if (!str_starts_with($name, 'test')) continue;
    $before = count(Redis_Test::$errors);
    $rt = new Redis_Test($host, (int) $port, null);
    try {
        $rt->setUp();
        $rt->$name();
        $r = count(Redis_Test::$errors) === $before ? 'PASSED' : 'FAILED';
    } catch (TestSkippedException $e) {
        $r = 'SKIPPED';
    } catch (Throwable $e) {
        $r = 'FAILED';
    }
    try { $rt->tearDown(); } catch (Throwable $e) {}
    $counts[$r] = ($counts[$r] ?? 0) + 1;
    echo "$name $r\n";
}
ksort($counts);
foreach ($counts as $r => $n) echo "== $r $n\n";
