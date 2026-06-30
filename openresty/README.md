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
    │   ├── junction_device.lua
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

Store JSON as a plain string value (not double-encoded). With `valkey-cli`, use single quotes around the JSON:

```bash
docker compose exec valkey valkey-cli SET 'session:ise1' '{"url":"https://10.10.10.30/admin/","device_type":"cisco_ise_tacacs","host":"ise.corp.local"}'
```

Verify parsing:

```bash
docker compose exec valkey valkey-cli GET 'session:ise1'
```

The proxy reads the `url` field for upstream targeting and `host` for the HTTP `Host` header.

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

## Device junctions

| Device | Junction path | `device_type` | Module |
|--------|---------------|---------------|--------|
| F5 BIG-IP Load Balancer | `/f5/{session_id}/`, `/f5lb/{session_id}/`, or `/f5_load_balancer/{session_id}/` | `f5_bigip` or `f5_load_balancer` | `devices/f5_bigip.lua` |
| Infoblox NIOS | `/infoblox/{session_id}/` | `infoblox` | `devices/infoblox.lua` |
| ZDNS | `/zdns/{session_id}/` | `zdns` | `devices/zdns.lua` |
| Cisco ISE (TACACS) | `/ise/{session_id}/` | `cisco_ise_tacacs` | `devices/cisco_ise_tacacs.lua` |
| FortiProxy | `/fortiproxy/{session_id}/` or `/fortiproxy_gui/{session_id}/` | `fortiproxy` or `fortiproxy_gui` | `devices/fortiproxy.lua` |

Proxy examples (after seeding a session):

```bash
curl -I "http://localhost:8080/f5/abc123/"
curl -I "http://localhost:8080/infoblox/abc123/"
curl -I "http://localhost:8080/zdns/abc123/"
curl -I "http://localhost:8080/ise/abc123/"
```

### Session examples

```bash
# F5 BIG-IP Load Balancer (TMUI)
docker compose exec valkey valkey-cli SET 'session:f5lb1' \
  '{"url":"https://10.10.10.10","device_type":"f5_load_balancer","host":"10.10.10.10"}'

# Infoblox NIOS
docker compose exec valkey valkey-cli SET 'session:infoblox1' \
  '{"url":"https://10.10.10.10","device_type":"infoblox","host":"10.10.10.10"}'

# ZDNS
docker compose exec valkey valkey-cli SET 'session:zdns1' \
  '{"url":"https://10.10.10.20","device_type":"zdns","host":"10.10.10.20"}'

# Cisco ISE TACACS admin
docker compose exec valkey valkey-cli SET 'session:ise1' \
  '{"url":"https://10.10.10.30/admin/","device_type":"cisco_ise_tacacs","host":"ise.corp.local"}'
```

Set `host` to the ISE FQDN when the appliance issues redirects using a hostname. Redirects are followed server-side using the session IP (`url`) while `Host` is set from `host`.

The ISE admin UI uses OWASP CSRFGuard (`/admin/JavaScriptServlet`). The junction rewrites upstream `Referer`/`Origin` headers back to the ISE URL, patches the servlet's `isValidDomain(document.domain, …)` check for the proxy host, and sets `Content-Type: application/javascript` when the servlet body is real JavaScript (not an HTML error page). Hard-refresh the browser if the servlet response was cached.

Infoblox, ZDNS, Cisco ISE, and F5 junctions follow upstream redirects server-side and rewrite `Location` headers for the browser.

**F5 tip:** TMUI lives under `/tmui/`. Visiting `/f5/{session_id}/` automatically opens `/tmui/login.jsp` on the F5. Set `host` to the F5 management hostname when the session `url` uses an IP address.

```bash
docker compose exec valkey valkey-cli SET 'session:f5lb1' \
  '{"url":"https://10.10.10.10","device_type":"f5_load_balancer","host":"bigip.corp.local"}'
```

Then open `http://localhost:8080/f5/f5lb1/`, `http://localhost:8080/f5lb/f5lb1/`, or `http://localhost:8080/f5_load_balancer/f5lb1/`.

The session id is the path segment **after** the junction prefix (not the Valkey key prefix). Example: Valkey key `session:f5lb1` → browser URL `/f5/f5lb1/` (not `/f5lb1/`).

**Valkey URL tip:** `https://10.10.10.10` and `https://10.10.10.10:443` are equivalent — port 443 is normalized automatically.

## Add a new device junction

1. Copy `lua/devices/_template.lua` to `lua/devices/<name>.lua` (or use `lib.junction_device.new()`)
2. Add a location block in `nginx/conf/junctions.conf`
3. Preload the module in `nginx/nginx.conf` `init_by_lua_block`

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

### JavaScript / regex safety

Bundled device JavaScript (for example FortiProxy `main.js`) often contains quoted regex patterns such as `'/(?:foo|bar)/'`. The rewriter skips strings that look like regex (metacharacters, `/pattern/gi` suffixes) and uses **strict JavaScript mode** for `.js` responses: only paths that look like real URLs (`/api/...`, `/static/...`, `/login`, file extensions, query strings) are prefixed.

If a device uses non-standard URL roots, add them to `JS_URL_ROOTS` in `lib/html_rewrite.lua` or create a device module that sets `strict_javascript = true` in `rewrite_body`.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VALKEY_HOST` | `127.0.0.1` | Valkey host |
| `VALKEY_PORT` | `6379` | Valkey port |
| `VALKEY_PASSWORD` | _(empty)_ | Valkey AUTH password |
| `SESSION_KEY_PREFIX` | `session:` | Prefix for session keys |
| `JUNCTION_BASE_PATH` | _(empty)_ | Strip a leading path prefix when the proxy is mounted under a subpath (example: `/proxy`) |

## Notes

- Update the `resolver` directive in `nginx/nginx.conf` for your environment (Docker DNS, kube-dns, etc.).
- `proxy_ssl_verify off` is enabled for typical lab device self-signed certificates. Tighten this in production if you terminate TLS to known backends.
- F5 module rewrites `Set-Cookie` paths so cookies stay scoped under `/f5/{session_id}/`.
