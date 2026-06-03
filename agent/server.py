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

            # UPDATED: Mapping the new public_ip field into the broadcast dictionary
            agents[instance_id] = {
                "hostname": metrics.get("hostname", "Ubuntu Node"),
                "private_ip": metrics.get("private_ip", "N/A"),
                "public_ip": metrics.get("public_ip", "N/A"),  # <-- ADDED
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