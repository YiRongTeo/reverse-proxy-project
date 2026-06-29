# OpenResty + Valkey Device GUI Junction Proxy

Reverse proxy junctions route browser traffic to network device GUIs. Each device type gets its own junction path and Lua module; session-to-backend mappings are stored in Valkey.

## Architecture

```mermaid
flowchart LR
    Browser -->|"/f5/{session_id}/..."| OpenResty
    OpenResty -->|GET session:{id}| Valkey
    Valkey -->|device GUI URL| OpenResty
    OpenResty -->|proxy| DeviceGUI[F5 / other device GUI]
```

- **Junction**: one URI prefix per device family (example: `/f5/`)
- **Session key**: Valkey key `session:{session_id}` → backend URL
- **Device Lua module**: CORS, headers, cookies, and other device-specific behavior

## Layout

```
openresty/
├── Dockerfile
├── docker-compose.yml
├── nginx/
│   ├── nginx.conf
│   └── conf/
│       ├── junctions.conf              # one location block per device
│       └── snippets/
│           └── junction-proxy.conf     # shared proxy + Lua hooks
└── lua/
    ├── junction/
    │   ├── access.lua                  # session lookup + upstream selection
    │   ├── content.lua                 # capture upstream body + rewrite
    │   └── header_filter.lua           # response header / CORS handling
    ├── lib/
    │   ├── valkey.lua
    │   ├── junction_session.lua
    │   ├── cors.lua
    │   ├── proxy_util.lua
    │   └── device_registry.lua
    └── devices/
        ├── f5_bigip.lua
        ├── infoblox.lua
        ├── zdns.lua
        ├── cisco_ise_tacacs.lua
        └── _template.lua
```

## Request flow

1. Client requests `GET /f5/abc123/tmui/login.jsp`
2. `access.lua` loads the device module from `junction_device`
3. Session ID `abc123` is read from the path
4. Valkey key `session:abc123` returns `https://10.10.10.10`
5. Request is proxied to `https://10.10.10.10/tmui/login.jsp`
6. `header_filter.lua` applies junction CORS and device-specific response fixes

## Valkey session format

Key:

```text
session:{session_id}
```

Value (plain URL):

```text
https://10.10.10.10
```

Value (JSON, recommended):

```json
{"url":"https://10.10.10.10","device_type":"f5_bigip","host":"10.10.10.10"}
```

Seed an example session:

```bash
docker compose exec valkey valkey-cli SET 'session:abc123' 'https://10.10.10.10'
```

## Run locally

```bash
cd openresty
docker compose up --build
curl http://localhost:8080/healthz
```

Proxy examples (after seeding a session):

```bash
# F5 BIG-IP
curl -I "http://localhost:8080/f5/abc123/"

# Infoblox NIOS
curl -I "http://localhost:8080/infoblox/abc123/"
```

### Infoblox session example

```bash
docker compose exec valkey valkey-cli SET 'session:abc123' \
  '{"url":"https://10.10.10.10","device_type":"infoblox","host":"10.10.10.10"}'
```

Then open `http://localhost:8080/infoblox/abc123/` in a browser. Infoblox typically responds with a 302 to `/wui/` on first access; the junction follows that redirect server-side and rewrites `Location` headers that reach the browser.

**Valkey URL tip:** `https://10.10.10.10` and `https://10.10.10.10:443` are equivalent — port 443 is normalized automatically.

## Add a new device junction

1. Copy `lua/devices/_template.lua` to `lua/devices/<name>.lua`
2. Register it in `lua/lib/device_registry.lua`
3. Add a location block in `nginx/conf/junctions.conf`:

```nginx
location /mydevice/ {
    set $junction_device "mydevice";
    set $junction_prefix "/mydevice";
    include conf/snippets/junction-proxy.conf;
}
```

The nginx config stays small because each device owns its logic in Lua.

## HTML / JS / CSS rewriting

Device GUIs often emit root-absolute paths (`<base href="/">`, `src="/.../runtime.js"`, `fetch('/api/...')`) that break behind a junction.

Rewriting uses `lua-resty-http` in `content.lua` to fetch the exact `device_upstream` URL (set during session lookup), rewrite the body in memory, then respond. This avoids `ngx.location.capture` sending the junction path (`/f5/...`) to the device instead of the real backend path.

| Pattern | Rewritten to |
|---------|--------------|
| `<base href="/">` | `<base href="/f5/{session_id}/">` |
| `src="/path/to/runtime.js"` | `src="/f5/{session_id}/path/to/runtime.js"` |
| `fetch('/api/v2/...')` | `fetch('/f5/{session_id}/api/v2/...')` |
| `Location: /logout` | `Location: /f5/{session_id}/logout` |
| `{{:host_addr}}` templates | proxy host |

If the page shows garbled characters, the device likely sent a compressed HTML/JS/CSS response. `lib/gzip.lua` decompresses only when `Content-Encoding` is set (or for text assets with gzip magic bytes). Binary assets such as PNG and WOFF are passed through without decompression.

Check `/var/log/nginx/error.log` for:

- `junction upstream fetch uri=... target=https://device/... upstream_bytes=N` — full body received from device
- `junction rewrite applied uri=... bytes=N->M` — body was rewritten

If `upstream_bytes=0`, the device returned an empty body (redirect, 304, or HEAD).

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VALKEY_HOST` | `127.0.0.1` | Valkey host |
| `VALKEY_PORT` | `6379` | Valkey port |
| `VALKEY_PASSWORD` | _(empty)_ | Valkey AUTH password |
| `SESSION_KEY_PREFIX` | `session:` | Prefix for session keys |

## Notes

- Update the `resolver` directive in `nginx/nginx.conf` for your environment (Docker DNS, kube-dns, etc.).
- `proxy_ssl_verify off` is enabled for typical lab device self-signed certificates. Tighten this in production if you terminate TLS to known backends.
- F5 module rewrites `Set-Cookie` paths so cookies stay scoped under `/f5/{session_id}/`.
