<?php
require __DIR__ . '/../packages/settings-ui/root/usr/local/emhttp/plugins/gow/php/health-lib.php';
$r = gow_run_health_checks([
    'APPDATA' => '/tmp/gow-devtest-appdata',
    'ROMS_LIBRARY' => '/mnt/user/games/roms',
    'DEPLOYED' => 'false',
]);
if (empty($r['checks'])) {
    fwrite(STDERR, "no checks\n");
    exit(1);
}
if (!in_array($r['summary'], ['healthy', 'degraded', 'unhealthy'], true)) {
    fwrite(STDERR, "bad summary\n");
    exit(1);
}
echo $r['summary'] . "\n";
