<?php
// What an app with APCu's and Xdebug's images as runtimes gets: both loaded
// through their .ini files, APCu's cache working, Xdebug's mode, and
// whether a debugging client took Xdebug's connection.
$scanned = array_map('basename', array_map('trim', explode(',', (string) php_ini_scanned_files())));
echo 'ini ', implode(' ', $scanned), "\n";
echo 'loaded ', extension_loaded('apcu') ? 'apcu' : '-', ' ', extension_loaded('xdebug') ? 'xdebug' : '-', "\n";
echo 'apcu ', apcu_store('answer', 41) && apcu_inc('answer') === 42 ? 'works' : 'fails', "\n";
echo 'xdebug mode ', implode(',', xdebug_info('mode')), ', debugger ', xdebug_is_debugger_active() ? 'connected' : 'not connected', "\n";
