<?php
// AJAX endpoint for live log tailing from the GoW settings page.

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

define('DEPLOY_LOG', '/tmp/gow-deploy.log');
define('UPDATE_LOG', '/tmp/gow-update.log');
define('AUTOSTART_LOG', '/tmp/gow-autostart.log');

$allowed_containers = ['wolf', 'wolf-den'];
$action = $_GET['action'] ?? 'tail';

function json_out($payload, $code = 200) {
    http_response_code($code);
    echo json_encode($payload);
    exit;
}

function read_file_tail($path, $max_bytes = 65536) {
    if (!is_readable($path)) {
        return ['exists' => false, 'text' => ''];
    }
    $size = filesize($path);
    if ($size === false) {
        return ['exists' => true, 'text' => ''];
    }
    if ($size <= $max_bytes) {
        return ['exists' => true, 'text' => file_get_contents($path) ?: ''];
    }
    $fh = fopen($path, 'rb');
    if (!$fh) {
        return ['exists' => true, 'text' => ''];
    }
    fseek($fh, -$max_bytes, SEEK_END);
    $text = stream_get_contents($fh) ?: '';
    fclose($fh);
    return ['exists' => true, 'text' => $text];
}

function docker_logs($container, $lines) {
    $lines = max(10, min(500, (int)$lines));
    $container = escapeshellarg($container);
    exec("docker logs --tail {$lines} {$container} 2>&1", $out, $ret);
    return [
        'running' => $ret === 0,
        'text'    => implode("\n", $out),
    ];
}

function docker_memory_stats($containers) {
    $stats = [];
    foreach ($containers as $container) {
        exec(
            'docker stats --no-stream --format ' . escapeshellarg('{{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}') . ' '
            . escapeshellarg($container) . ' 2>/dev/null',
            $out,
            $ret
        );
        if ($ret === 0 && !empty($out[0])) {
            $parts = explode("\t", $out[0]);
            $stats[$container] = [
                'usage' => $parts[1] ?? '',
                'percent' => $parts[2] ?? '',
            ];
        }
    }
    return $stats;
}

switch ($action) {
    case 'memory':
        $stats = docker_memory_stats($allowed_containers);
        $sessions = [];
        exec('docker ps --filter "name=Wolf" --format "{{.Names}}\t{{.Status}}" 2>/dev/null', $session_out);
        foreach ($session_out as $line) {
            $line = ltrim(trim(explode("\t", $line)[0] ?? ''), '/');
            if ($line === '' || $line === 'wolf' || $line === 'wolf-den') {
                continue;
            }
            if (strncmp($line, 'Wolf', 4) === 0) {
                $sessions[] = $line;
            }
        }
        json_out([
            'stats' => $stats,
            'sessions' => $sessions,
        ]);
        break;

    case 'tail':
        $container = $_GET['container'] ?? '';
        if (!in_array($container, $allowed_containers, true)) {
            json_out(['error' => 'Invalid container'], 400);
        }
        $lines = $_GET['lines'] ?? 150;
        $result = docker_logs($container, $lines);
        json_out([
            'container' => $container,
            'running'   => $result['running'],
            'text'      => $result['text'],
        ]);
        break;

    case 'deploy':
        $file = read_file_tail(DEPLOY_LOG);
        exec("pgrep -f '/boot/config/plugins/gow/scripts/deploy.sh'", $pids);
        json_out([
            'active' => !empty($pids),
            'exists' => $file['exists'],
            'text'   => $file['text'],
        ]);
        break;

    case 'update':
        $file = read_file_tail(UPDATE_LOG);
        exec("pgrep -f '/boot/config/plugins/gow/scripts/update.sh'", $pids);
        json_out([
            'active' => !empty($pids),
            'exists' => $file['exists'],
            'text'   => $file['text'],
        ]);
        break;

    case 'autostart':
        $file = read_file_tail(AUTOSTART_LOG);
        json_out([
            'exists' => $file['exists'],
            'text'   => $file['text'],
        ]);
        break;

    default:
        json_out(['error' => 'Unknown action'], 400);
}
