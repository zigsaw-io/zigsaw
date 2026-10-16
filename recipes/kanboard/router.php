<?php
// router.php: PHP's built-in web server runs this first for each request
// (see serve.php). Web servers that read Kanboard's .htaccess files keep
// app\ from the web; this refuses it too, and the other directories of code
// that aren't pages (libs\, vendor\, the cli script). The rest goes to the
// server as usual. Kanboard's data isn't under the served directory.

$path = rawurldecode((string) parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH));
if (preg_match('#^[/\\\\]+(app|libs|vendor|cli)([/\\\\.]|$)#i', $path)) {
    http_response_code(403);
    echo "Forbidden\n";
    return true;
}
return false;
