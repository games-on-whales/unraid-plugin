<?php
// health.php — JSON health check endpoint for the GoW dashboard and setup form.

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

require_once __DIR__ . '/health-lib.php';

$mode = $_GET['mode'] ?? 'deployed';
$cfg = gow_load_cfg_for_health();

if ($mode === 'setup') {
    $result = gow_run_setup_health_checks($cfg, gow_detect_gpus_simple());
} else {
    $result = gow_run_health_checks($cfg);
}

echo json_encode($result);
