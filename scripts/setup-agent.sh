#!/bin/bash

# 1. Update and install dependencies non-interactively
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt upgrade -y
apt install python3 python3-pip python3-venv nginx curl -y

# 2. Set up the project directory in /opt (standard for 3rd party apps)
PROJECT_DIR="/opt/monitoring-server"
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR

# 3. Create virtual environment and install packages
python3 -m venv venv
$PROJECT_DIR/venv/bin/pip install fastapi uvicorn websockets psutil requests

# 4. Generate the FastAPI backend script automatically
cat << 'EOF' > $PROJECT_DIR/server.py
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
import json
import asyncio
import time

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

agents = {}
frontend_clients = []

@app.websocket("/agent")
async def agent_socket(websocket: WebSocket):
    await websocket.accept()
    instance_id = None

    try:
        while True:
            data = await websocket.receive_text()
            metrics = json.loads(data)
            instance_id = metrics["instance_id"]

            agents[instance_id] = {
                "hostname": metrics.get("hostname", "Ubuntu Node"),
                "private_ip": metrics.get("private_ip", "N/A"),
                "public_ip": metrics.get("public_ip", "N/A"),
                "cpu": metrics.get("cpu", 0),
                "memory": metrics.get("memory", 0),
                "disk": metrics.get("disk", 0),
                "network_sent": metrics.get("network_sent", 0),
                "network_recv": metrics.get("network_recv", 0),
                "disk_read": metrics.get("disk_read", 0),
                "disk_write": metrics.get("disk_write", 0),
                "logs": metrics.get("logs", []),
                "status": "ONLINE",
                "last_seen": time.time()
            }

            disconnected_clients = []
            for client in frontend_clients:
                try:
                    await client.send_text(json.dumps(agents))
                except:
                    disconnected_clients.append(client)

            for client in disconnected_clients:
                frontend_clients.remove(client)

    except WebSocketDisconnect:
        if instance_id in agents:
            agents[instance_id]["status"] = "OFFLINE"
            for client in frontend_clients:
                try:
                    await client.send_text(json.dumps(agents))
                except:
                    pass

@app.websocket("/dashboard")
async def dashboard_socket(websocket: WebSocket):
    await websocket.accept()
    frontend_clients.append(websocket)
    try:
        while True:
            await asyncio.sleep(1)
    except:
        if websocket in frontend_clients:
            frontend_clients.remove(websocket)

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)
EOF

# 5. Create a Systemd Service for the FastAPI Server
# This pushes the Python script to the background and ensures it restarts on server reboot
cat << 'EOF' > /etc/systemd/system/monitoring-backend.service
[Unit]
Description=FastAPI Monitoring Backend Service
After=network.target

[Service]
User=root
WorkingDirectory=/opt/monitoring-server
ExecStart=/opt/monitoring-server/venv/bin/python server.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# 6. Start the Backend Service
systemctl daemon-reload
systemctl enable monitoring-backend
systemctl start monitoring-backend

# 7. Generate the Frontend Dashboard directly into Nginx's web folder
cat << 'EOF' > /var/www/html/index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>realtime-ec2-telemetry</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
    <style>
        /* ═══════════════════════════════════════════════
           DESIGN TOKENS
        ═══════════════════════════════════════════════ */
        :root {
            --bg-dark: #06090f;
            --bg-surface: #0c1220;
            --card-bg: rgba(15, 23, 42, 0.75);
            --sidebar-bg: rgba(10, 17, 32, 0.85);
            --terminal-bg: #020408;
            --text-main: #e2e8f0;
            --text-bright: #f8fafc;
            --text-muted: #64748b;
            --text-dim: #475569;
            --accent: #3b82f6;
            --accent-glow: rgba(59, 130, 246, 0.35);
            --success: #10b981;
            --success-dim: rgba(16, 185, 129, 0.15);
            --danger: #ef4444;
            --danger-dim: rgba(239, 68, 68, 0.15);
            --warning: #f59e0b;
            --warning-dim: rgba(245, 158, 11, 0.15);
            --border: rgba(255, 255, 255, 0.06);
            --border-hover: rgba(255, 255, 255, 0.12);
            --samdev-purple: #c026d3;
            --samdev-pink: #db2777;
            --samdev-blue: #38bdf8;
            --neon-cyan: #22d3ee;
            --neon-purple: #a855f7;
            --glass-blur: 16px;
        }

        /* ═══════════════════════════════════════════════
           RESET & BASE
        ═══════════════════════════════════════════════ */
        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

        html, body {
            height: 100%;
            overflow: hidden;
        }

        body {
            background-color: var(--bg-dark);
            color: var(--text-main);
            font-family: 'Inter', system-ui, -apple-system, sans-serif;
        }

        ::-webkit-scrollbar { width: 5px; }
        ::-webkit-scrollbar-track { background: transparent; }
        ::-webkit-scrollbar-thumb { background: rgba(100, 116, 139, 0.3); border-radius: 10px; }
        ::-webkit-scrollbar-thumb:hover { background: rgba(100, 116, 139, 0.5); }

        /* ═══════════════════════════════════════════════
           CURSOR NEON GLOW TRACKER
        ═══════════════════════════════════════════════ */
        #cursor-glow {
            position: fixed;
            width: 500px;
            height: 500px;
            border-radius: 50%;
            pointer-events: none;
            z-index: 1;
            background: radial-gradient(
                circle at center,
                rgba(59, 130, 246, 0.12) 0%,
                rgba(139, 92, 246, 0.06) 30%,
                rgba(34, 211, 238, 0.03) 50%,
                transparent 70%
            );
            transform: translate(-50%, -50%);
            transition: opacity 0.3s ease;
            will-change: left, top;
            filter: blur(2px);
        }

        #cursor-glow-inner {
            position: fixed;
            width: 180px;
            height: 180px;
            border-radius: 50%;
            pointer-events: none;
            z-index: 1;
            background: radial-gradient(
                circle at center,
                rgba(59, 130, 246, 0.18) 0%,
                rgba(168, 85, 247, 0.08) 40%,
                transparent 70%
            );
            transform: translate(-50%, -50%);
            will-change: left, top;
        }

        /* ═══════════════════════════════════════════════
           SCI-FI BACKGROUND LAYERS
        ═══════════════════════════════════════════════ */
        #scifi-bg {
            position: fixed;
            inset: 0;
            z-index: 0;
            overflow: hidden;
            pointer-events: none;
        }

        /* Animated grid */
        #scifi-bg .grid-layer {
            position: absolute;
            inset: -50%;
            width: 200%;
            height: 200%;
            background-image:
                linear-gradient(rgba(59, 130, 246, 0.04) 1px, transparent 1px),
                linear-gradient(90deg, rgba(59, 130, 246, 0.04) 1px, transparent 1px);
            background-size: 60px 60px;
            animation: grid-drift 30s linear infinite;
        }

        @keyframes grid-drift {
            0% { transform: translate(0, 0) rotate(0deg); }
            100% { transform: translate(60px, 60px) rotate(0.5deg); }
        }

        /* Hex pattern overlay */
        #scifi-bg .hex-layer {
            position: absolute;
            inset: 0;
            background-image:
                radial-gradient(ellipse 80px 80px at 20% 30%, rgba(168, 85, 247, 0.04) 0%, transparent 70%),
                radial-gradient(ellipse 120px 120px at 70% 20%, rgba(34, 211, 238, 0.03) 0%, transparent 70%),
                radial-gradient(ellipse 100px 100px at 50% 70%, rgba(59, 130, 246, 0.04) 0%, transparent 70%),
                radial-gradient(ellipse 90px 90px at 80% 80%, rgba(192, 38, 211, 0.03) 0%, transparent 70%);
            animation: hex-pulse 12s ease-in-out infinite alternate;
        }

        @keyframes hex-pulse {
            0% { opacity: 0.5; }
            100% { opacity: 1; }
        }

        /* Scanning line */
        #scifi-bg .scan-line {
            position: absolute;
            left: 0;
            width: 100%;
            height: 2px;
            background: linear-gradient(90deg,
                transparent 0%,
                rgba(59, 130, 246, 0.15) 20%,
                rgba(34, 211, 238, 0.3) 50%,
                rgba(59, 130, 246, 0.15) 80%,
                transparent 100%
            );
            animation: scan 8s linear infinite;
            box-shadow: 0 0 20px rgba(59, 130, 246, 0.1);
        }

        @keyframes scan {
            0% { top: -2px; }
            100% { top: 100%; }
        }

        /* Floating particles via canvas */
        #particle-canvas {
            position: absolute;
            inset: 0;
            width: 100%;
            height: 100%;
        }

        /* Corner decorations */
        .corner-deco {
            position: absolute;
            width: 120px;
            height: 120px;
            pointer-events: none;
        }
        .corner-deco.tl { top: 0; left: 0; border-top: 1px solid rgba(59,130,246,0.15); border-left: 1px solid rgba(59,130,246,0.15); }
        .corner-deco.tr { top: 0; right: 0; border-top: 1px solid rgba(168,85,247,0.15); border-right: 1px solid rgba(168,85,247,0.15); }
        .corner-deco.bl { bottom: 0; left: 0; border-bottom: 1px solid rgba(168,85,247,0.15); border-left: 1px solid rgba(168,85,247,0.15); }
        .corner-deco.br { bottom: 0; right: 0; border-bottom: 1px solid rgba(59,130,246,0.15); border-right: 1px solid rgba(59,130,246,0.15); }


        /* ═══════════════════════════════════════════════
           LAYOUT SHELL
        ═══════════════════════════════════════════════ */
        .app-shell {
            position: relative;
            z-index: 2;
            display: flex;
            flex-direction: column;
            height: 100vh;
        }

        /* ─── Header ─── */
        .header-nav {
            background: rgba(10, 17, 32, 0.8);
            backdrop-filter: blur(var(--glass-blur));
            -webkit-backdrop-filter: blur(var(--glass-blur));
            padding: 12px 24px;
            display: flex;
            align-items: center;
            border-bottom: 1px solid var(--border);
            flex-shrink: 0;
        }

        .logo-container {
            display: flex;
            align-items: center;
            gap: 10px;
            margin-right: 24px;
        }

        .logo-mark { width: 28px; height: 28px; }

        .logo-text { display: flex; flex-direction: column; line-height: 1; }
        .samdev { font-size: 1.15rem; font-weight: 800; color: #fff; letter-spacing: -0.02em; }
        .studio { font-size: 0.7rem; color: var(--samdev-blue); font-weight: 600; text-transform: uppercase; letter-spacing: 0.15em; }

        .header-title {
            font-size: 1rem;
            font-weight: 500;
            color: var(--text-muted);
            border-left: 1px solid var(--border);
            padding-left: 24px;
        }

        .header-right {
            margin-left: auto;
            display: flex;
            align-items: center;
            gap: 16px;
        }

        .connection-status {
            display: flex;
            align-items: center;
            gap: 6px;
            font-size: 0.75rem;
            font-family: 'JetBrains Mono', monospace;
            color: var(--text-muted);
            padding: 5px 12px;
            border-radius: 20px;
            background: rgba(255,255,255,0.03);
            border: 1px solid var(--border);
        }

        .connection-dot {
            width: 6px; height: 6px;
            border-radius: 50%;
            background: var(--danger);
            transition: background 0.3s, box-shadow 0.3s;
        }
        .connection-dot.connected {
            background: var(--success);
            box-shadow: 0 0 8px var(--success);
            animation: pulse-dot 2s infinite;
        }

        @keyframes pulse-dot {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.5; }
        }

        .live-clock {
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.75rem;
            color: var(--text-dim);
        }

        /* ─── Content Area ─── */
        .content-area {
            display: flex;
            flex: 1;
            overflow: hidden;
        }

        /* ─── Sidebar ─── */
        .sidebar {
            width: 300px;
            min-width: 300px;
            background: var(--sidebar-bg);
            backdrop-filter: blur(var(--glass-blur));
            -webkit-backdrop-filter: blur(var(--glass-blur));
            border-right: 1px solid var(--border);
            display: flex;
            flex-direction: column;
            overflow: hidden;
        }

        .sidebar-header {
            padding: 18px 16px 14px;
            border-bottom: 1px solid var(--border);
            flex-shrink: 0;
        }

        .sidebar-header h3 {
            font-size: 0.65rem;
            text-transform: uppercase;
            letter-spacing: 0.15em;
            color: var(--text-dim);
            font-weight: 600;
            margin-bottom: 4px;
        }

        .instance-count {
            font-size: 0.75rem;
            color: var(--text-muted);
            font-family: 'JetBrains Mono', monospace;
        }

        .instance-list {
            flex: 1;
            overflow-y: auto;
            padding: 8px;
        }

        .instance-item {
            display: flex;
            align-items: center;
            gap: 12px;
            padding: 12px;
            border-radius: 10px;
            cursor: pointer;
            border: 1px solid transparent;
            margin-bottom: 4px;
            transition: all 0.2s ease;
            position: relative;
        }

        .instance-item:hover {
            background: rgba(59, 130, 246, 0.05);
            border-color: rgba(59, 130, 246, 0.1);
        }

        .instance-item.active {
            background: rgba(59, 130, 246, 0.08);
            border-color: rgba(59, 130, 246, 0.25);
            box-shadow: inset 0 0 20px rgba(59, 130, 246, 0.05);
        }

        .instance-item.active::before {
            content: '';
            position: absolute;
            left: 0;
            top: 50%;
            transform: translateY(-50%);
            width: 3px;
            height: 60%;
            background: var(--accent);
            border-radius: 0 3px 3px 0;
            box-shadow: 0 0 10px var(--accent-glow);
        }

        .instance-avatar {
            width: 36px;
            height: 36px;
            border-radius: 10px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-family: 'JetBrains Mono', monospace;
            font-weight: 700;
            font-size: 0.7rem;
            flex-shrink: 0;
            position: relative;
        }

        .instance-avatar.online {
            background: var(--success-dim);
            color: var(--success);
            border: 1px solid rgba(16, 185, 129, 0.2);
        }

        .instance-avatar.offline {
            background: var(--danger-dim);
            color: var(--danger);
            border: 1px solid rgba(239, 68, 68, 0.2);
        }

        .instance-avatar .status-ring {
            position: absolute;
            bottom: -2px;
            right: -2px;
            width: 10px;
            height: 10px;
            border-radius: 50%;
            border: 2px solid var(--bg-surface);
        }

        .instance-avatar.online .status-ring {
            background: var(--success);
            box-shadow: 0 0 6px var(--success);
        }

        .instance-avatar.offline .status-ring {
            background: var(--danger);
        }

        .instance-info {
            flex: 1;
            min-width: 0;
        }

        .instance-name {
            font-size: 0.8rem;
            font-weight: 600;
            color: var(--text-bright);
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }

        .instance-id-text {
            font-size: 0.65rem;
            font-family: 'JetBrains Mono', monospace;
            color: var(--text-dim);
            margin-top: 2px;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }

        .instance-mini-stats {
            display: flex;
            gap: 8px;
            margin-top: 4px;
        }

        .mini-stat {
            font-size: 0.6rem;
            font-family: 'JetBrains Mono', monospace;
            color: var(--text-muted);
            display: flex;
            align-items: center;
            gap: 3px;
        }

        .mini-stat .dot {
            width: 4px;
            height: 4px;
            border-radius: 50%;
        }

        /* ─── Main Panel ─── */
        .main-panel {
            flex: 1;
            overflow-y: auto;
            padding: 28px 32px;
            position: relative;
        }

        .no-selection {
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            height: 100%;
            color: var(--text-dim);
            gap: 12px;
        }

        .no-selection svg { opacity: 0.15; }
        .no-selection p { font-size: 0.9rem; }

        /* ─── Detail View ─── */
        .detail-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            margin-bottom: 24px;
        }

        .detail-title-block {
            display: flex;
            align-items: center;
            gap: 16px;
        }

        .detail-icon {
            width: 48px;
            height: 48px;
            border-radius: 14px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 1.3rem;
        }

        .detail-icon.online {
            background: linear-gradient(135deg, rgba(16, 185, 129, 0.15), rgba(59, 130, 246, 0.1));
            border: 1px solid rgba(16, 185, 129, 0.2);
        }
        .detail-icon.offline {
            background: linear-gradient(135deg, rgba(239, 68, 68, 0.15), rgba(239, 68, 68, 0.05));
            border: 1px solid rgba(239, 68, 68, 0.2);
        }

        .detail-hostname {
            font-size: 1.5rem;
            font-weight: 700;
            color: var(--text-bright);
        }

        .detail-status-badge {
            display: flex;
            align-items: center;
            gap: 8px;
            font-size: 0.8rem;
            font-weight: 600;
            padding: 8px 16px;
            border-radius: 24px;
        }

        .detail-status-badge.online {
            color: var(--success);
            background: var(--success-dim);
            border: 1px solid rgba(16, 185, 129, 0.2);
        }
        .detail-status-badge.offline {
            color: var(--danger);
            background: var(--danger-dim);
            border: 1px solid rgba(239, 68, 68, 0.2);
        }

        .detail-status-badge .pulse-ring {
            width: 8px; height: 8px;
            border-radius: 50%;
        }

        .detail-status-badge.online .pulse-ring {
            background: var(--success);
            box-shadow: 0 0 10px var(--success);
            animation: pulse-green 2s infinite;
        }
        .detail-status-badge.offline .pulse-ring {
            background: var(--danger);
        }

        @keyframes pulse-green {
            0% { transform: scale(0.95); box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.7); }
            70% { transform: scale(1); box-shadow: 0 0 0 8px rgba(16, 185, 129, 0); }
            100% { transform: scale(0.95); box-shadow: 0 0 0 0 rgba(16, 185, 129, 0); }
        }

        /* Identity Tags */
        .identity-tags {
            display: flex;
            flex-wrap: wrap;
            gap: 8px;
            margin-bottom: 28px;
        }

        .tag {
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.7rem;
            padding: 6px 12px;
            border-radius: 8px;
            background: rgba(59, 130, 246, 0.06);
            color: #93c5fd;
            border: 1px solid rgba(59, 130, 246, 0.12);
            display: flex;
            align-items: center;
            gap: 6px;
        }

        .tag .label {
            color: var(--text-dim);
            font-weight: 500;
        }

        /* Metrics Row */
        .metrics-row {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 16px;
            margin-bottom: 28px;
        }

        .metric-card {
            background: var(--card-bg);
            backdrop-filter: blur(var(--glass-blur));
            border: 1px solid var(--border);
            border-radius: 14px;
            padding: 18px;
            transition: border-color 0.2s, transform 0.2s;
        }

        .metric-card:hover {
            border-color: var(--border-hover);
            transform: translateY(-2px);
        }

        .metric-card .metric-label {
            font-size: 0.65rem;
            text-transform: uppercase;
            letter-spacing: 0.1em;
            color: var(--text-dim);
            font-weight: 600;
            margin-bottom: 8px;
            display: flex;
            align-items: center;
            gap: 6px;
        }

        .metric-card .metric-label .icon {
            width: 14px; height: 14px;
            opacity: 0.5;
        }

        .metric-card .metric-val {
            font-size: 1.35rem;
            font-weight: 700;
            color: var(--text-bright);
            font-family: 'JetBrains Mono', monospace;
        }

        .metric-card .metric-sub {
            font-size: 0.65rem;
            color: var(--text-dim);
            margin-top: 4px;
            font-family: 'JetBrains Mono', monospace;
        }

        /* Gauge Bars */
        .gauges-section {
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 16px;
            margin-bottom: 28px;
        }

        .gauge-card {
            background: var(--card-bg);
            backdrop-filter: blur(var(--glass-blur));
            border: 1px solid var(--border);
            border-radius: 14px;
            padding: 20px;
            transition: border-color 0.2s, transform 0.2s;
        }

        .gauge-card:hover {
            border-color: var(--border-hover);
            transform: translateY(-2px);
        }

        .gauge-header {
            display: flex;
            justify-content: space-between;
            align-items: baseline;
            margin-bottom: 12px;
        }

        .gauge-title {
            font-size: 0.75rem;
            font-weight: 600;
            color: var(--text-muted);
            text-transform: uppercase;
            letter-spacing: 0.05em;
        }

        .gauge-value {
            font-size: 1.6rem;
            font-weight: 800;
            font-family: 'JetBrains Mono', monospace;
        }

        .gauge-track {
            width: 100%;
            height: 8px;
            background: rgba(255, 255, 255, 0.04);
            border-radius: 10px;
            overflow: hidden;
            position: relative;
        }

        .gauge-fill {
            height: 100%;
            border-radius: 10px;
            transition: width 0.6s cubic-bezier(0.22, 1, 0.36, 1);
            position: relative;
        }

        .gauge-fill::after {
            content: '';
            position: absolute;
            right: 0;
            top: -2px;
            width: 4px;
            height: 12px;
            border-radius: 2px;
            background: inherit;
            filter: brightness(1.3);
            box-shadow: 0 0 8px currentColor;
        }

        .gauge-fill.blue { background: linear-gradient(90deg, #1d4ed8, #3b82f6); color: #3b82f6; }
        .gauge-fill.amber { background: linear-gradient(90deg, #b45309, #f59e0b); color: #f59e0b; }
        .gauge-fill.red { background: linear-gradient(90deg, #b91c1c, #ef4444); color: #ef4444; }

        /* Log Terminal */
        .log-section {
            background: var(--card-bg);
            backdrop-filter: blur(var(--glass-blur));
            border: 1px solid var(--border);
            border-radius: 14px;
            overflow: hidden;
        }

        .log-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            padding: 14px 18px;
            border-bottom: 1px solid var(--border);
        }

        .log-header-left {
            display: flex;
            align-items: center;
            gap: 10px;
        }

        .log-header h4 {
            font-size: 0.7rem;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.1em;
            color: var(--text-muted);
        }

        .terminal-dots {
            display: flex;
            gap: 5px;
        }
        .terminal-dots span {
            width: 8px; height: 8px;
            border-radius: 50%;
        }
        .terminal-dots .d1 { background: #ef4444; }
        .terminal-dots .d2 { background: #f59e0b; }
        .terminal-dots .d3 { background: #22c55e; }

        .log-body {
            background: var(--terminal-bg);
            padding: 16px;
            height: 240px;
            overflow-y: auto;
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.72rem;
            line-height: 1.7;
        }

        .log-line {
            display: flex;
            gap: 8px;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
            padding: 2px 0;
            color: rgba(56, 189, 248, 0.8);
            border-left: 2px solid rgba(56, 189, 248, 0.15);
            padding-left: 10px;
            margin-bottom: 2px;
            transition: background 0.15s;
        }

        .log-line:hover {
            background: rgba(56, 189, 248, 0.03);
        }

        .log-line.empty {
            color: var(--text-dim);
            border-left-color: transparent;
            font-style: italic;
        }

        .log-line .timestamp {
            color: var(--text-dim);
            flex-shrink: 0;
        }

        /* ═══════════════════════════════════════════════
           RESPONSIVE
        ═══════════════════════════════════════════════ */
        @media (max-width: 1200px) {
            .metrics-row { grid-template-columns: repeat(2, 1fr); }
            .gauges-section { grid-template-columns: 1fr; }
        }

        @media (max-width: 768px) {
            .sidebar { width: 220px; min-width: 220px; }
            .main-panel { padding: 16px; }
            .metrics-row { grid-template-columns: 1fr; }
        }

        /* ═══════════════════════════════════════════════
           ANIMATIONS
        ═══════════════════════════════════════════════ */
        @keyframes fadeInUp {
            from { opacity: 0; transform: translateY(12px); }
            to { opacity: 1; transform: translateY(0); }
        }

        .animate-in {
            animation: fadeInUp 0.35s ease-out forwards;
        }

        .animate-in:nth-child(2) { animation-delay: 0.05s; }
        .animate-in:nth-child(3) { animation-delay: 0.1s; }
        .animate-in:nth-child(4) { animation-delay: 0.15s; }
    </style>
</head>
<body>
    <!-- Cursor Neon Glow -->
    <div id="cursor-glow"></div>
    <div id="cursor-glow-inner"></div>

    <!-- Sci-Fi Background -->
    <div id="scifi-bg">
        <div class="grid-layer"></div>
        <div class="hex-layer"></div>
        <div class="scan-line"></div>
        <canvas id="particle-canvas"></canvas>
        <div class="corner-deco tl"></div>
        <div class="corner-deco tr"></div>
        <div class="corner-deco bl"></div>
        <div class="corner-deco br"></div>
    </div>

    <!-- App Shell -->
    <div class="app-shell">
        <!-- Header -->
        <div class="header-nav">
            <div class="logo-container">
                <svg class="logo-mark" viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
                    <path d="M10 90 L50 10 L90 90" stroke="url(#logo-grad)" stroke-width="12" stroke-linecap="round" fill="none"/>
                    <defs>
                        <linearGradient id="logo-grad" x1="0%" y1="0%" x2="100%" y2="100%">
                            <stop offset="0%" style="stop-color:#c026d3"/>
                            <stop offset="100%" style="stop-color:#db2777"/>
                        </linearGradient>
                    </defs>
                </svg>
                <div class="logo-text">
                    <span class="samdev">SamDev</span>
                    <span class="studio">studio</span>
                </div>
            </div>
            <h1 class="header-title">Distributed EC2 Monitoring Dashboard</h1>

            <div class="header-right">
                <div class="connection-status">
                    <div class="connection-dot" id="ws-dot"></div>
                    <span id="ws-status">Disconnected</span>
                </div>
                <div class="live-clock" id="live-clock"></div>
            </div>
        </div>

        <!-- Content -->
        <div class="content-area">
            <!-- Sidebar -->
            <div class="sidebar">
                <div class="sidebar-header">
                    <h3>Fleet Instances</h3>
                    <div class="instance-count" id="instance-count">0 instances</div>
                </div>
                <div class="instance-list" id="instance-list">
                    <!-- Populated by JS -->
                </div>
            </div>

            <!-- Main Panel -->
            <div class="main-panel" id="main-panel">
                <div class="no-selection" id="empty-state">
                    <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1">
                        <rect x="2" y="3" width="20" height="14" rx="2"/>
                        <path d="M8 21h8M12 17v4"/>
                    </svg>
                    <p>Select an instance from the fleet panel</p>
                </div>
                <div id="detail-view" style="display: none;"></div>
            </div>
        </div>
    </div>

    <script>
        /* ═══════════════════════════════════════════════
           CURSOR GLOW TRACKER
        ═══════════════════════════════════════════════ */
        const cursorGlow = document.getElementById('cursor-glow');
        const cursorGlowInner = document.getElementById('cursor-glow-inner');
        let mouseX = 0, mouseY = 0;
        let glowX = 0, glowY = 0;
        let innerX = 0, innerY = 0;

        document.addEventListener('mousemove', (e) => {
            mouseX = e.clientX;
            mouseY = e.clientY;
        });

        function animateGlow() {
            // Outer glow — slower, floaty follow
            glowX += (mouseX - glowX) * 0.06;
            glowY += (mouseY - glowY) * 0.06;
            cursorGlow.style.left = glowX + 'px';
            cursorGlow.style.top = glowY + 'px';

            // Inner glow — faster, tighter follow
            innerX += (mouseX - innerX) * 0.15;
            innerY += (mouseY - innerY) * 0.15;
            cursorGlowInner.style.left = innerX + 'px';
            cursorGlowInner.style.top = innerY + 'px';

            requestAnimationFrame(animateGlow);
        }
        animateGlow();

        /* ═══════════════════════════════════════════════
           PARTICLE SYSTEM
        ═══════════════════════════════════════════════ */
        const canvas = document.getElementById('particle-canvas');
        const ctx = canvas.getContext('2d');

        function resizeCanvas() {
            canvas.width = window.innerWidth;
            canvas.height = window.innerHeight;
        }
        resizeCanvas();
        window.addEventListener('resize', resizeCanvas);

        class Particle {
            constructor() { this.reset(); }
            reset() {
                this.x = Math.random() * canvas.width;
                this.y = Math.random() * canvas.height;
                this.size = Math.random() * 1.5 + 0.3;
                this.speedX = (Math.random() - 0.5) * 0.3;
                this.speedY = (Math.random() - 0.5) * 0.3;
                this.opacity = Math.random() * 0.3 + 0.05;
                this.hue = Math.random() > 0.5 ? 210 : 270; // blue or purple
            }
            update() {
                this.x += this.speedX;
                this.y += this.speedY;
                if (this.x < 0 || this.x > canvas.width || this.y < 0 || this.y > canvas.height) {
                    this.reset();
                }
            }
            draw() {
                ctx.beginPath();
                ctx.arc(this.x, this.y, this.size, 0, Math.PI * 2);
                ctx.fillStyle = `hsla(${this.hue}, 70%, 65%, ${this.opacity})`;
                ctx.fill();
            }
        }

        const particles = Array.from({ length: 60 }, () => new Particle());

        function drawParticles() {
            ctx.clearRect(0, 0, canvas.width, canvas.height);
            particles.forEach(p => { p.update(); p.draw(); });

            // Draw faint connections
            for (let i = 0; i < particles.length; i++) {
                for (let j = i + 1; j < particles.length; j++) {
                    const dx = particles[i].x - particles[j].x;
                    const dy = particles[i].y - particles[j].y;
                    const dist = Math.sqrt(dx * dx + dy * dy);
                    if (dist < 150) {
                        ctx.beginPath();
                        ctx.moveTo(particles[i].x, particles[i].y);
                        ctx.lineTo(particles[j].x, particles[j].y);
                        ctx.strokeStyle = `rgba(59, 130, 246, ${0.04 * (1 - dist / 150)})`;
                        ctx.lineWidth = 0.5;
                        ctx.stroke();
                    }
                }
            }
            requestAnimationFrame(drawParticles);
        }
        drawParticles();

        /* ═══════════════════════════════════════════════
           LIVE CLOCK
        ═══════════════════════════════════════════════ */
        function updateClock() {
            const now = new Date();
            document.getElementById('live-clock').textContent = now.toLocaleTimeString('en-US', {
                hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit'
            }) + ' UTC' + (now.getTimezoneOffset() > 0 ? '-' : '+') + Math.abs(now.getTimezoneOffset() / 60);
        }
        setInterval(updateClock, 1000);
        updateClock();

        /* ═══════════════════════════════════════════════
           DASHBOARD STATE
        ═══════════════════════════════════════════════ */
        let fleetData = {};
        let selectedInstanceId = null;

        /* ═══════════════════════════════════════════════
           HELPERS
        ═══════════════════════════════════════════════ */
        function formatBytes(value) {
            if (!value || isNaN(value)) return value || '0 B';
            const num = parseFloat(value);
            if (num === 0) return '0 B';
            const k = 1024;
            const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
            const i = Math.floor(Math.log(num) / Math.log(k));
            return parseFloat((num / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
        }

        function getGaugeClass(pct) {
            if (pct < 60) return 'blue';
            if (pct < 85) return 'amber';
            return 'red';
        }

        function getGaugeColor(pct) {
            if (pct < 60) return 'var(--accent)';
            if (pct < 85) return 'var(--warning)';
            return 'var(--danger)';
        }

        function escapeHtml(str) {
            return str.replace(/</g, '&lt;').replace(/>/g, '&gt;');
        }

        function truncateId(id) {
            if (id.length > 14) return id.substring(0, 6) + '…' + id.substring(id.length - 5);
            return id;
        }

        /* ═══════════════════════════════════════════════
           RENDER SIDEBAR
        ═══════════════════════════════════════════════ */
        function renderSidebar() {
            const list = document.getElementById('instance-list');
            const keys = Object.keys(fleetData);
            document.getElementById('instance-count').textContent = keys.length + ' instance' + (keys.length !== 1 ? 's' : '');

            // Auto-select first if nothing selected
            if (!selectedInstanceId && keys.length > 0) {
                selectedInstanceId = keys[0];
            }

            list.innerHTML = keys.map(id => {
                const inst = fleetData[id];
                const isOnline = inst.status === 'ONLINE';
                const statusClass = isOnline ? 'online' : 'offline';
                const isActive = id === selectedInstanceId;
                const cpu = parseFloat(inst.cpu) || 0;
                const mem = parseFloat(inst.memory) || 0;

                return `
                    <div class="instance-item ${isActive ? 'active' : ''}" data-id="${id}" onclick="selectInstance('${id}')">
                        <div class="instance-avatar ${statusClass}">
                            ${(inst.hostname || 'N')[0].toUpperCase()}
                            <div class="status-ring"></div>
                        </div>
                        <div class="instance-info">
                            <div class="instance-name">${inst.hostname || 'Unknown Host'}</div>
                            <div class="instance-id-text">${truncateId(id)}</div>
                            <div class="instance-mini-stats">
                                <span class="mini-stat">
                                    <span class="dot" style="background:${getGaugeColor(cpu)}"></span>
                                    CPU ${cpu.toFixed(0)}%
                                </span>
                                <span class="mini-stat">
                                    <span class="dot" style="background:${getGaugeColor(mem)}"></span>
                                    MEM ${mem.toFixed(0)}%
                                </span>
                            </div>
                        </div>
                    </div>
                `;
            }).join('');
        }

        /* ═══════════════════════════════════════════════
           RENDER DETAIL VIEW
        ═══════════════════════════════════════════════ */
        function renderDetail() {
            const emptyState = document.getElementById('empty-state');
            const detailView = document.getElementById('detail-view');

            if (!selectedInstanceId || !fleetData[selectedInstanceId]) {
                emptyState.style.display = 'flex';
                detailView.style.display = 'none';
                return;
            }

            emptyState.style.display = 'none';
            detailView.style.display = 'block';

            const inst = fleetData[selectedInstanceId];
            const isOnline = inst.status === 'ONLINE';
            const statusClass = isOnline ? 'online' : 'offline';
            const cpu = parseFloat(inst.cpu) || 0;
            const mem = parseFloat(inst.memory) || 0;
            const disk = parseFloat(inst.disk) || 0;

            let logsHTML = '';
            if (inst.logs && inst.logs.length > 0) {
                inst.logs.forEach(log => {
                    if (log && log.trim().length > 0) {
                        logsHTML += `<div class="log-line">${escapeHtml(log)}</div>`;
                    }
                });
            }
            if (!logsHTML) {
                logsHTML = '<div class="log-line empty">No active log streams found</div>';
            }

            detailView.innerHTML = `
                <!-- Header -->
                <div class="detail-header animate-in">
                    <div class="detail-title-block">
                        <div class="detail-icon ${statusClass}">
                            <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="${isOnline ? 'var(--success)' : 'var(--danger)'}" stroke-width="1.5">
                                <rect x="2" y="3" width="20" height="14" rx="2"/>
                                <path d="M8 21h8M12 17v4"/>
                            </svg>
                        </div>
                        <div>
                            <div class="detail-hostname">${inst.hostname || 'Ubuntu Node'}</div>
                        </div>
                    </div>
                    <div class="detail-status-badge ${statusClass}">
                        <div class="pulse-ring"></div>
                        ${inst.status || 'OFFLINE'}
                    </div>
                </div>

                <!-- Identity Tags -->
                <div class="identity-tags animate-in">
                    <div class="tag"><span class="label">ID</span> ${selectedInstanceId}</div>
                    <div class="tag"><span class="label">Private IP</span> ${inst.private_ip || 'N/A'}</div>
                    <div class="tag"><span class="label">Public IP</span> ${inst.public_ip || 'N/A'}</div>
                </div>

                <!-- Metrics -->
                <div class="metrics-row animate-in">
                    <div class="metric-card">
                        <div class="metric-label">
                            <svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 20V4M5 12l7-8 7 8"/></svg>
                            Net Sent
                        </div>
                        <div class="metric-val">${formatBytes(inst.network_sent)}</div>
                        <div class="metric-sub">outbound</div>
                    </div>
                    <div class="metric-card">
                        <div class="metric-label">
                            <svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 4v16M19 12l-7 8-7-8"/></svg>
                            Net Recv
                        </div>
                        <div class="metric-val">${formatBytes(inst.network_recv)}</div>
                        <div class="metric-sub">inbound</div>
                    </div>
                    <div class="metric-card">
                        <div class="metric-label">
                            <svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/></svg>
                            Disk Read
                        </div>
                        <div class="metric-val">${formatBytes(inst.disk_read)}</div>
                        <div class="metric-sub">I/O read</div>
                    </div>
                    <div class="metric-card">
                        <div class="metric-label">
                            <svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M17 3a2.85 2.85 0 114 4L7.5 20.5 2 22l1.5-5.5Z"/></svg>
                            Disk Write
                        </div>
                        <div class="metric-val">${formatBytes(inst.disk_write)}</div>
                        <div class="metric-sub">I/O write</div>
                    </div>
                </div>

                <!-- Gauges -->
                <div class="gauges-section animate-in">
                    <div class="gauge-card">
                        <div class="gauge-header">
                            <span class="gauge-title">CPU Usage</span>
                            <span class="gauge-value" style="color:${getGaugeColor(cpu)}">${cpu.toFixed(1)}%</span>
                        </div>
                        <div class="gauge-track">
                            <div class="gauge-fill ${getGaugeClass(cpu)}" style="width:${cpu}%"></div>
                        </div>
                    </div>
                    <div class="gauge-card">
                        <div class="gauge-header">
                            <span class="gauge-title">Memory</span>
                            <span class="gauge-value" style="color:${getGaugeColor(mem)}">${mem.toFixed(1)}%</span>
                        </div>
                        <div class="gauge-track">
                            <div class="gauge-fill ${getGaugeClass(mem)}" style="width:${mem}%"></div>
                        </div>
                    </div>
                    <div class="gauge-card">
                        <div class="gauge-header">
                            <span class="gauge-title">Disk</span>
                            <span class="gauge-value" style="color:${getGaugeColor(disk)}">${disk.toFixed(1)}%</span>
                        </div>
                        <div class="gauge-track">
                            <div class="gauge-fill ${getGaugeClass(disk)}" style="width:${disk}%"></div>
                        </div>
                    </div>
                </div>

                <!-- Log Terminal -->
                <div class="log-section animate-in">
                    <div class="log-header">
                        <div class="log-header-left">
                            <div class="terminal-dots">
                                <span class="d1"></span>
                                <span class="d2"></span>
                                <span class="d3"></span>
                            </div>
                            <h4>System Log Terminal — syslog</h4>
                        </div>
                        <span style="font-size:0.65rem;color:var(--text-dim);font-family:'JetBrains Mono',monospace;">${inst.hostname || 'node'}@${inst.private_ip || '0.0.0.0'}</span>
                    </div>
                    <div class="log-body" id="log-terminal">
                        ${logsHTML}
                    </div>
                </div>
            `;

            // Auto-scroll log terminal
            const terminal = document.getElementById('log-terminal');
            if (terminal) terminal.scrollTop = terminal.scrollHeight;
        }

        /* ═══════════════════════════════════════════════
           INSTANCE SELECTION
        ═══════════════════════════════════════════════ */
        function selectInstance(id) {
            selectedInstanceId = id;
            renderSidebar();
            renderDetail();
        }

        /* ═══════════════════════════════════════════════
           WEBSOCKET
        ═══════════════════════════════════════════════ */
        const wsDot = document.getElementById('ws-dot');
        const wsStatus = document.getElementById('ws-status');

        function connectWebSocket() {
            const socket = new WebSocket('ws://<!--public-instance-ip-->:8080/dashboard');  

            socket.onopen = function() {
                wsDot.classList.add('connected');
                wsStatus.textContent = 'Live';
            };

            socket.onmessage = function(event) {
                const data = JSON.parse(event.data);
                fleetData = data;

                // If selected instance no longer exists, reset
                if (selectedInstanceId && !fleetData[selectedInstanceId]) {
                    selectedInstanceId = Object.keys(fleetData)[0] || null;
                }

                renderSidebar();
                renderDetail();
            };

            socket.onerror = function(error) {
                console.error('WebSocket Error:', error);
            };

            socket.onclose = function() {
                wsDot.classList.remove('connected');
                wsStatus.textContent = 'Reconnecting…';
                setTimeout(connectWebSocket, 3000);
            };
        }

        connectWebSocket();
    </script>
</body>
</html>

EOF

# 8. Start and Enable Nginx
systemctl enable nginx
systemctl restart nginx
