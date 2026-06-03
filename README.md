# Cloud Fleet Monitor 🚀

A real-time, distributed telemetry and fleet monitoring dashboard designed for AWS EC2 clusters. This project provides full-stack visibility into system performance metrics without relying on heavy third-party monitoring packages.

### 🛠️ Tech Stack
* **Backend:** FastAPI, Uvicorn, WebSockets (Asynchronous python server)
* **Agent:** Python (`psutil`, `websockets`, `requests`) running as a managed `systemd` daemon
* **Frontend:** Clean HTML5/CSS3, JavaScript (WebSockets API, Chart.js), Nginx
* **Deployment:** Fully automated bash automation via EC2 User Data

### ✨ Core Features
* **Live Streaming Telemetry:** Sub-second server state updates using persistent WebSocket connections.
* **Lightweight Monitoring:** Minimal agent footprint tracking CPU, Memory, Disk, Network I/O, and Disk Write/Read footprints.
* **Log Aggregation:** Pulls system logs straight from host machines to track server health live.
* **Step-Line Graph Visualization:** Real-time telemetry values mapped dynamically over a historical window using Chart.js.
