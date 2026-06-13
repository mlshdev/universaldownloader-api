# Reaching the API with curl

Quick reference for exercising the Video Download API from the command line and
for debugging connection problems. Pair this with the debug logs (set
`API_LOG_LEVEL=debug`) — every request is tagged with a short `request_id` that
also comes back in the `X-Request-ID` response header, so you can match a curl
call to its server-side log lines.

## Setting up shell variables

```bash
# Where the API lives. Pick the one that matches your deployment:
BASE_URL="http://localhost:8000"          # direct to the container/uvicorn
# BASE_URL="http://localhost"             # behind Traefik on port 80
# BASE_URL="https://api.yourdomain.com"   # behind Traefik with HTTPS

TOKEN="your-secret-token-here"            # one of AUTH_TOKENS
```

## Health check (no auth)

The fastest way to confirm the server is up and reachable:

```bash
curl -i "$BASE_URL/health"
```

Expected:

```
HTTP/1.1 200 OK
x-request-id: 1a2b3c4d
content-type: application/json

{"status":"healthy","version":"1.0.0"}
```

If this fails, the problem is network/proxy reachability, not auth — see
[Troubleshooting](#troubleshooting-connection-issues).

## Download a video

```bash
curl -X POST "$BASE_URL/download" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}' \
  --output video.mp4
```

The response body is the binary MP4, so always use `--output` (or `-o`). The
suggested filename is in the `Content-Disposition` header; to keep the
server-provided name use `-OJ`:

```bash
curl -OJ -X POST "$BASE_URL/download" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://twitter.com/user/status/123456"}'
```

### Response status codes

| Status | Meaning |
|--------|---------|
| `200`  | Video file returned as attachment (`video/mp4`) |
| `400`  | Invalid URL or download error |
| `401`  | Missing or invalid auth token |
| `403`  | Video is private/unavailable |
| `404`  | Video not found |
| `422`  | Request body failed validation (e.g. `url` missing or not a URL) |
| `500`  | Processing failed |

## Troubleshooting connection issues

Run curl with `-v` to see exactly what happens at the connection layer, and turn
the server up to debug (`API_LOG_LEVEL=debug`, restart the container) so you get
the full redacted header dump and auth trace for each request.

### See full request/response detail

```bash
curl -v "$BASE_URL/health"
```

`-v` shows DNS resolution, TCP connect, TLS handshake, and the request/response
headers — enough to tell apart "can't connect" from "connected but rejected".

### Symptom → likely cause

- **`curl: (7) Failed to connect`** — Nothing is listening at `BASE_URL`. Check
  the container is running and the port is published (`docker compose ps`), and
  that you're using the right port (`8000` direct vs `80` via Traefik).
- **`curl: (6) Could not resolve host`** — DNS for your domain isn't pointing at
  the server. Test the raw IP/port first.
- **`curl: (35/60) SSL ...`** — TLS/cert problem at the proxy. Try the plain
  `http://` direct port to confirm the app itself is healthy.
- **`401 Missing Authorization header`** — No `Authorization` header reached the
  app. Confirm the header is actually sent (`-v`) and that a proxy isn't
  stripping it. Server log line: `Auth rejected: Authorization header absent`.
- **`401 Invalid authentication token`** — Header arrived but the token doesn't
  match `AUTH_TOKENS`. The debug log shows the received `token_len` and whether a
  `Bearer ` prefix was present (the actual token value is never logged).
- **`404` from a proxy (HTML, not JSON)** — You hit Traefik/another proxy, not
  the app. The app's 404s are JSON. Check routing rules and the path.
- **502 / 504** — Proxy reached but the app didn't respond. Check the container
  logs for the matching `request_id` (or that the app started at all).

### Matching a curl call to server logs

Every response carries an `X-Request-ID`. Grab it and grep the logs:

```bash
RID=$(curl -s -D - -o /dev/null "$BASE_URL/health" | awk -F': ' 'tolower($1)=="x-request-id"{print $2}' | tr -d '\r')
echo "request id: $RID"
docker logs video-download-api 2>&1 | grep "$RID"
```

You'll see the inbound line (method, path, client IP, `X-Forwarded-For`, proto,
host, user-agent), the redacted headers at debug, the auth decision, and the
outbound status + latency.

### Verifying proxy headers (behind Traefik)

The app trusts `X-Forwarded-*` (uvicorn runs with `--proxy-headers
--forwarded-allow-ips='*'`). To confirm the proxy is setting them, send them
yourself against the direct port and watch the log:

```bash
curl -s "$BASE_URL/health" \
  -H "X-Forwarded-For: 203.0.113.9" \
  -H "X-Forwarded-Proto: https" \
  -H "X-Forwarded-Host: api.yourdomain.com"
```

The inbound log line will echo `xff=203.0.113.9 proto=https host=api.yourdomain.com`.
If real client requests show `xff=-`, your proxy isn't forwarding them.
