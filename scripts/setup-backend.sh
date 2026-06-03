#!/bin/bash

# 1. Update and install dependencies
apt update -y
apt install python3 python3-pip python3-venv curl -y

pip3 install websockets psutil requests --break-system-packages

mkdir -p /opt/custom-monitor-agent

# 2. Generate the modernized Python agent script
cat << 'EOF' > /opt/custom-monitor-agent/agent.py

import asyncio
import websockets
import psutil
import socket
import json
import time
import requests
import subprocess

MONITOR_SERVER = "<Agent-Server-Public-IP>"
MONITOR_PORT = 8080

def get_aws_metadata():
    """Fetches AWS Instance ID, Private IP, and Public IP using IMDSv2."""
    try:
        # Request the mandatory IMDSv2 Security Token (Valid for 6 hours)
        token_url = "http://169.254.169.254/latest/api/token"
        token_headers = {"X-aws-ec2-metadata-token-ttl-seconds": "21600"}
        token = requests.put(token_url, headers=token_headers, timeout=2).text

        # Use the token to securely extract the metadata
        meta_headers = {"X-aws-ec2-metadata-token": token}
        
        i_id = requests.get("http://169.254.169.254/latest/meta-data/instance-id", headers=meta_headers, timeout=2).text
        priv_ip = requests.get("http://169.254.169.254/latest/meta-data/local-ipv4", headers=meta_headers, timeout=2).text
        
        try:
            pub_ip = requests.get("http://169.254.169.254/latest/meta-data/public-ipv4", headers=meta_headers, timeout=2).text
        except Exception:
            pub_ip = "N/A" # Failsafe in case the instance doesn't have a public IP assigned
            
        return i_id, priv_ip, pub_ip
    except Exception as e:
        print(f"AWS Metadata Error: {e}")
        return "unknown-instance", "unknown-private", "N/A"

# Retrieve identity data ONCE when the script starts
instance_id, private_ip, public_ip = get_aws_metadata()
hostname = socket.gethostname()

async def send_metrics():
    uri = f"ws://{MONITOR_SERVER}:{MONITOR_PORT}/agent"

    while True:
        try:
            async with websockets.connect(uri) as websocket:
                while True:
                    cpu = psutil.cpu_percent()
                    memory = psutil.virtual_memory().percent
                    disk = psutil.disk_usage('/').percent

                    net = psutil.net_io_counters()
                    disk_io = psutil.disk_io_counters()

                    try:
                        result = subprocess.check_output(['tail', '-5', '/var/log/syslog']).decode()
                        logs = result.split('\n')
                    except:
                        logs = ["No logs available"]

                    payload = {
                        "instance_id": instance_id,
                        "public_ip": public_ip,      # Added public IP to the payload
                        "hostname": hostname,
                        "private_ip": private_ip,
                        "cpu": cpu,
                        "memory": memory,
                        "disk": disk,
                        "network_sent": net.bytes_sent,
                        "network_recv": net.bytes_recv,
                        "disk_read": disk_io.read_bytes,
                        "disk_write": disk_io.write_bytes,
                        "logs": logs
                    }

                    await websocket.send(json.dumps(payload))
                    await asyncio.sleep(3)

        except Exception as e:
            print(f"WebSocket Connection Error: {e}")
            await asyncio.sleep(5)

asyncio.run(send_metrics())

EOF

# 3. Create the Systemd Service
cat << 'EOF' > /etc/systemd/system/custom-monitor-agent.service

[Unit]
Description=Custom Monitoring Agent
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/custom-monitor-agent/agent.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target

EOF

# 4. Reload and Restart the Service
systemctl daemon-reload
systemctl enable custom-monitor-agent
systemctl restart custom-monitor-agent