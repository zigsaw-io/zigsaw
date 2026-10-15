<?php
// zigsaw's test extension, built with zig, in PHP's official build: prints
// one line per check, "ok" or "FAIL", and the fatal-error check last, which
// ends the script through a bailout (exit code 255).
function check($name, $got, $want) {
    $ok = $got === $want;
    echo ($ok ? "ok   " : "FAIL ") . $name . ($ok ? "" : " got " . var_export($got, true) . " want " . var_export($want, true)) . "\n";
}

echo "compiler: ", zprobe_compiler(), "\n";
check("loaded", extension_loaded("zprobe"), true);
check("constant", ZPROBE_ANSWER, 42);
check("loaded by its image's .ini", str_contains((string) php_ini_scanned_files(), "zprobe.ini"), true);
check("config.w32", zprobe_config(), "hello from config.w32, version info: yes");
check("repeat", zprobe_repeat("ab", 3), "ab,ab,ab");
check("repeat sep", zprobe_repeat("x", 4, "--"), "x--x--x--x");
check("repeat 0", zprobe_repeat("x", 0), "");
check("big repeat", strlen(zprobe_repeat(str_repeat("y", 1000), 5000)), 1000 * 5000 + 4999);
check("sum", zprobe_sum([1, 2.5, "3", "4.25", true]), 11.75);
check("map", zprobe_map(["a" => 1, 5 => 2], fn($v, $k) => "$k=" . ($v * 10)), ["a" => "a=10", 5 => "5=20"]);
check("map closure state", (function () { $n = 0; zprobe_map(range(1, 100), function ($v) use (&$n) { $n += $v; }); return $n; })(), 5050);
try { zprobe_throw("boom", 7); check("throw", "no exception", "exception"); }
catch (Exception $e) { check("throw", [$e->getMessage(), $e->getCode()], ["boom", 7]); }
try { zprobe_map([1, 2], function ($v) { if ($v == 2) throw new RuntimeException("inner"); return $v; }); }
catch (RuntimeException $e) { check("exception through map", $e->getMessage(), "inner"); }
try { zprobe_repeat("a"); } catch (ArgumentCountError $e) { check("arg count error", get_class($e), "ArgumentCountError"); }
try { zprobe_repeat([], 1); } catch (TypeError $e) { check("type error", str_contains($e->getMessage(), "must be of type string"), true); }
$p = new ZProbe\Point(3, 4);
check("method", $p->length(), 5.0);
check("custom object", $p->weight(), 7.0);
check("property", [$p->x, $p->y], [3.0, 4.0]);
$q = clone $p; $q->x = 6; $q->y = 8;
check("clone", [$q->length(), $p->length()], [10.0, 5.0]);
unset($p, $q);
$tmp = tempnam(sys_get_temp_dir(), "zp");
file_put_contents($tmp, "stream data\n");
check("stream", zprobe_read($tmp), "stream data\n");
unlink($tmp);
check("format", zprobe_format(1.25, -9, "s"), "1.250|-9|s|1.25|hello");
ini_set("zprobe.greeting", "bonjour");
check("ini", zprobe_format(0.5, 1, "t"), "0.500|1|t|0.5|bonjour");
ob_start(); phpinfo(INFO_MODULES); $info = ob_get_clean();
check("minfo", str_contains($info, "zprobe support => enabled"), true);
$objs = []; for ($i = 0; $i < 20000; $i++) $objs[] = new ZProbe\Point($i, 1); unset($objs);
check("many objects", gc_collect_cycles() >= 0, true);
check("calls", zprobe_calls(), 5);

register_shutdown_function(function () {
    echo (zprobe_bailed() ? "ok   " : "FAIL ") . "fatal error unwound through zend_try in the extension\n";
    echo "shutdown ok\n";
});
ini_set("memory_limit", "16M");
echo "fatal next:\n";
zprobe_guard(function () { return zprobe_map([1], fn() => str_repeat("x", 64 * 1024 * 1024)); });
echo "FAIL not reached\n";
