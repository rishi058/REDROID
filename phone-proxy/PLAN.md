Yes. With your setup, I’d build it in **three stages** so we can isolate failures cleanly:

```text
                    INTERNET
                       │
             https://proxy.example.com
                       │
                 Coolify / HTTPS
                       │
                 ┌─────▼─────┐
                 │  Relay    │
                 │  :8000    │
                 └─────┬─────┘
                       │
                HTTP proxy
                       │
                 ┌─────▼─────┐
                 │   frps    │
                 │   :7000   │
                 └─────┬─────┘
                       │ FRP tunnel
                       ▼
                 Android / Termux
                       │
                 frpc → :8080
                       │
                  Every Proxy
                       │
                       ▼
                    INTERNET
                  via phone IP
```

FRP's current release is **v0.71.0**, and the official release includes an `android_arm64` client package; the official `frps` image also supports ARM64. ([GitHub][1])

---

# 1. Configure Oracle / Coolify

We'll run **FRP server + relay in one Docker Compose stack**.

Create a private repo:

```text
phone-proxy/
├── compose.yml
├── frps.toml
└── relay/
    ├── Dockerfile
    ├── requirements.txt
    └── main.py
```

### `frps.toml`

```toml
bindAddr = "0.0.0.0"
bindPort = 7000

auth.method = "token"
auth.token = "{{ .Envs.FRP_TOKEN }}"

allowPorts = [
  { single = 18080 }
]

maxPortsPerClient = 1

transport.tls.force = true
transport.tcpKeepalive = 30
transport.tcpMuxKeepaliveInterval = 30
transport.heartbeatTimeout = 90
```

FRP supports token authentication, TLS, port allowlists, and connection heartbeat settings; TOML plus environment-template rendering are supported in current releases. ([GoFRP][2])

### `compose.yml`

```yaml
services:

  frps:
    image: ghcr.io/fatedier/frps:v0.71.0
    restart: unless-stopped

    environment:
      FRP_TOKEN: ${FRP_TOKEN}

    command:
      - -c
      - /etc/frp/frps.toml

    volumes:
      - ./frps.toml:/etc/frp/frps.toml:ro

    ports:
      - "7000:7000"

    expose:
      - "18080"

    networks:
      - phoneproxy

  relay:
    build:
      context: ./relay

    restart: unless-stopped

    environment:
      RELAY_KEY: ${RELAY_KEY}
      PHONE_PROXY: http://${PHONE_PROXY_USER}:${PHONE_PROXY_PASS}@frps:18080

    expose:
      - "8000"

    depends_on:
      - frps

    networks:
      - phoneproxy

networks:
  phoneproxy:
```

Notice:

```text
7000 → public
18080 → NOT public
8000 → exposed through Coolify
```

That is intentional. We don't want your Every Proxy endpoint directly exposed to the Internet.

---

# 2. Create the relay

The relay turns:

```text
https://proxy.example.com/<key>/fetch?url=...
```

into:

```text
Oracle relay
    ↓
HTTP proxy at frps:18080
    ↓
FRP
    ↓
Every Proxy
    ↓
target
```

`Every Proxy` supports HTTP proxying including HTTPS via `CONNECT`, so it works for this design. ([Every Proxy][3])

### `relay/requirements.txt`

```text
fastapi
uvicorn[standard]
httpx
```

### `relay/Dockerfile`

```dockerfile
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### `relay/main.py`

```python
import os

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import Response, StreamingResponse
from starlette.background import BackgroundTask

app = FastAPI()

RELAY_KEY = os.environ["RELAY_KEY"]
PHONE_PROXY = os.environ["PHONE_PROXY"]

client = httpx.AsyncClient(
    proxy=PHONE_PROXY,
    follow_redirects=True,
    timeout=httpx.Timeout(
        connect=20,
        read=None,
        write=30,
        pool=20,
    ),
    limits=httpx.Limits(
        max_connections=20,
        max_keepalive_connections=10,
    ),
)


@app.get("/health")
async def health():
    return {"ok": True}


@app.api_route("/{key}/fetch", methods=["GET", "HEAD"])
async def fetch(key: str, request: Request):

    if key != RELAY_KEY:
        raise HTTPException(status_code=404)

    target_url = request.query_params.get("url")
    if not target_url:
        raise HTTPException(status_code=400, detail="Missing url")

    if not target_url.startswith(("http://", "https://")):
        raise HTTPException(status_code=400, detail="Only HTTP/HTTPS URLs are allowed")

    headers = {
        "Accept-Encoding": "identity",
    }

    # Preserve download ranges.
    for header in (
        "range",
        "if-range",
        "if-none-match",
        "if-modified-since",
    ):
        value = request.headers.get(header)
        if value:
            headers[header] = value

    # Allow the caller to provide the required User-Agent.
    user_agent = request.query_params.get("ua")
    if user_agent:
        headers["User-Agent"] = user_agent

    referer = request.query_params.get("referer")
    if referer:
        headers["Referer"] = referer

    req = client.build_request(
        request.method,
        target_url,
        headers=headers,
    )

    response = await client.send(req, stream=True)

    response_headers = {}

    for name in (
        "content-type",
        "content-length",
        "content-range",
        "accept-ranges",
        "content-disposition",
        "etag",
        "last-modified",
        "cache-control",
    ):
        if name in response.headers:
            response_headers[name] = response.headers[name]

    if request.method == "HEAD":
        await response.aclose()
        return Response(
            status_code=response.status_code,
            headers=response_headers,
        )

    return StreamingResponse(
        response.aiter_raw(),
        status_code=response.status_code,
        headers=response_headers,
        background=BackgroundTask(response.aclose),
    )
```

The important part is `stream=True`: Oracle does **not download the whole video first**. It streams the response through the phone.

---

# 3. Coolify deployment

In Coolify:

**New Resource → Docker Compose → your Git repository**

Add these environment variables:

```text
FRP_TOKEN=<random-64-char-token>

RELAY_KEY=<random-64-char-key>

PHONE_PROXY_USER=<random-user>

PHONE_PROXY_PASS=<random-password>
```

Generate values such as:

```bash
openssl rand -hex 32
```

For username/password, use simple hex strings so URL escaping isn't an issue.

### Domain

Create:

```text
proxy.example.com
```

DNS:

```text
A   proxy   YOUR_ORACLE_PUBLIC_IP
```

Then in Coolify assign this domain to the **relay service**:

```text
https://proxy.example.com:8000
```

Coolify uses its integrated proxy to route the HTTPS domain to the service's internal port and can automatically manage TLS. ([Coolify][4])

For a Compose deployment, enable **Connect To Predefined Network** if required by your Coolify networking setup so the Coolify proxy can reach the service. ([Coolify][5])

---

# 4. Oracle firewall

You only need FRP's server port publicly accessible:

```text
TCP 7000
```

Open it in:

**OCI → VCN → Security List / NSG → Ingress Rules**

```text
Source: 0.0.0.0/0
Protocol: TCP
Destination port: 7000
```

And on Ubuntu, when UFW is active:

```bash
sudo ufw allow 7000/tcp
```

Do **not** open:

```text
18080
8000
```

to the public Internet.

Coolify already handles `80/443`.

---

# 5. Set up Every Proxy

On Android:

### Every Proxy

Enable:

```text
HTTP Proxy
Port: 8080
```

For security, configure:

```text
Username: <PHONE_PROXY_USER>
Password: <PHONE_PROXY_PASS>
```

Prefer binding to `0.0.0.0` only if necessary; because FRP connects to `127.0.0.1`, use the most restrictive binding available.

Every Proxy supports HTTP/HTTPS forwarding without root. ([Every Proxy][3])

Also enable **Auto Start**. Current Every Proxy documentation specifically provides an Auto Start option. ([Every Proxy][6])

And set:

```text
Settings
→ Apps
→ Every Proxy
→ Battery
→ Unrestricted
```

The developer recommends unrestricted battery usage for persistent operation. ([Every Proxy][7])

---

# 6. Install FRP on Termux

First verify architecture:

```bash
uname -m
```

Your phone should normally return:

```text
aarch64
```

Download the current Android ARM64 release:

```bash
pkg update
pkg install curl tar
```

```bash
mkdir -p ~/frp
cd ~/frp
```

```bash
curl -LO https://github.com/fatedier/frp/releases/download/v0.71.0/frp_0.71.0_android_arm64.tar.gz
```

```bash
tar -xzf frp_0.71.0_android_arm64.tar.gz
```

```bash
cp frp_0.71.0_android_arm64/frpc .
chmod +x frpc
```

The official v0.71.0 release provides this exact Android ARM64 artifact. ([GitHub][1])

---

# 7. Create `frpc.toml`

```toml
serverAddr = "YOUR_ORACLE_PUBLIC_IP"
serverPort = 7000

auth.method = "token"
auth.token = "YOUR_FRP_TOKEN"

loginFailExit = false

transport.protocol = "tcp"
transport.tcpMux = true

transport.dialServerKeepalive = 30
transport.tcpMuxKeepaliveInterval = 30
transport.heartbeatInterval = -1
transport.heartbeatTimeout = 90

transport.tls.enable = true

[[proxies]]
name = "phone-http-proxy"
type = "tcp"

localIP = "127.0.0.1"
localPort = 8080

remotePort = 18080
```

The `loginFailExit = false`, TCP keepalive/multiplexing, and heartbeat settings are supported by the current FRP client configuration. ([GoFRP][8])

Verify:

```bash
./frpc verify -c ./frpc.toml
```

Then:

```bash
./frpc -c ./frpc.toml
```

You want to see successful login and proxy registration.

At this point:

```text
Every Proxy :8080
       ↓
frpc
       ↓
Internet
       ↓
frps
       ↓
18080
```

---

# 8. Test the complete chain

Now call:

```text
https://proxy.example.com/<RELAY_KEY>/fetch?url=https%3A%2F%2Fapi.ipify.org
```

It should return your **phone's public IP**, not Oracle's IP.

That's the critical test.

You can also pass your required UA:

```text
https://proxy.example.com/<RELAY_KEY>/fetch?url=<ENCODED_URL>&ua=<ENCODED_USER_AGENT>
```

For example from your service:

```bash
curl -G \
  "https://proxy.example.com/<RELAY_KEY>/fetch" \
  --data-urlencode "url=https://example.com/file.mp4" \
  --data-urlencode "ua=Mozilla/5.0 ..."
```

---

# 9. Make Termux survive reboot

Install **Termux:Boot** from F-Droid, open it once, then create:

```bash
mkdir -p ~/.termux/boot
```

The official Termux:Boot addon executes scripts placed in this directory at boot and explicitly recommends `termux-wake-lock` for persistent processes. ([GitHub][9])

Create:

```bash
nano ~/.termux/boot/10-frpc
```

Put:

```bash
#!/data/data/com.termux/files/usr/bin/sh

termux-wake-lock

sleep 15

while true
do
    cd "$HOME/frp"

    ./frpc -c ./frpc.toml >> "$HOME/frp/frpc.log" 2>&1

    sleep 5
done
```

Then:

```bash
chmod +x ~/.termux/boot/10-frpc
```

Also set **Termux → Battery → Unrestricted**.

The combination is:

```text
Phone reboot
   ↓
Every Proxy auto-start
   ↓
Termux:Boot
   ↓
frpc
   ↓
FRP reconnect
```

---

# ⚠️ One important limitation

This architecture can be **highly persistent**, but nothing can honestly guarantee 24/7 availability because the phone itself can:

```text
lose mobile connectivity
restart
lose signal
have its background processes killed
run out of battery
```

Every Proxy's own documentation identifies Android battery/process management as a major source of disconnects. ([Every Proxy][7])

FRP addresses the **SSH problem**: when the phone-side connection disappears and the process remains alive, FRP can reconnect rather than requiring you to manually recreate an SSH tunnel.

## Final result

Your existing stack becomes:

```text
                 YOUR SERVICE
                      │
                      ▼
       https://proxy.example.com/<key>/fetch
                      │
                      ▼
            ┌─────────────────┐
            │ Oracle + Coolify│
            │                 │
            │ HTTPS           │
            │ FastAPI relay   │
            │ FRP server      │
            └────────┬────────┘
                     │
                  FRP :7000
                     │
                     ▼
                  TERMUX
                   frpc
                     │
                     ▼
               Every Proxy
                  :8080
                     │
                     ▼
              PHONE INTERNET
```

**This is the architecture I'd use for your situation.** It retains **Termux + Every Proxy**, eliminates the fragile SSH tunnel, gives you a fixed HTTPS URL, and keeps the Oracle VPS as the public/reliable component.

The most sensible next step is to **deploy only FRP first and verify `api.ipify.org` shows the phone IP** before adding the relay. That makes troubleshooting much easier.

[1]: https://github.com/fatedier/frp/releases?utm_source=chatgpt.com "Releases · fatedier/frp · GitHub"
[2]: https://gofrp.org/en/docs/features/common/authentication/?utm_source=chatgpt.com "Authentication | frp"
[3]: https://www.everyproxy.co.uk/http-proxy/?utm_source=chatgpt.com "HTTP & HTTPS - Every Proxy"
[4]: https://coolify.io/docs/core/networking/domains?utm_source=chatgpt.com "Domains | Coolify Docs"
[5]: https://coolify.io/docs/core/networking-in-coolify?utm_source=chatgpt.com "Networking in Coolify | Coolify Docs"
[6]: https://www.everyproxy.co.uk/how-to-use-every-proxy/?utm_source=chatgpt.com "Quick Start & How it Works - Every Proxy"
[7]: https://www.everyproxy.co.uk/battery-optimizations/?utm_source=chatgpt.com "Battery Optimizations - Every Proxy"
[8]: https://gofrp.org/en/docs/reference/client-configures/?utm_source=chatgpt.com "Client Configuration | frp"
[9]: https://github.com/termux/termux-boot?utm_source=chatgpt.com "GitHub - termux/termux-boot: Termux add-on app allowing programs to be run at boot. · GitHub"
