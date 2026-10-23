# Deploy on a public VPS (HTTPS)

Expose Benito behind TLS for parents who are away from home. Still **self-hosted** — not a multi-tenant SaaS.

## Prerequisites

- VPS with Docker + Compose
- Domain (or IP + TLS via your preferred method)
- Firewall allowing `80`/`443` only (not raw `8080` to the world)

## Compose

Same as home:

```bash
export SESSION_SECRET="$(openssl rand -hex 32)"
docker compose up -d --build
```

`docker-compose.yml` already publishes the app on loopback only (`127.0.0.1:${BENITO_PORT:-8080}:8080`), so it is reachable by a reverse proxy running on the same host but not from the internet. The examples below assume Caddy/nginx run on the host (not inside the compose network); if you set `BENITO_PORT`, point the proxy at that port instead of `8080`.

## Caddy example

```caddyfile
benito.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

## nginx example

```nginx
server {
    listen 443 ssl http2;
    server_name benito.example.com;
    # ssl_certificate / ssl_certificate_key ...

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

WebSocket `/sync` needs the Upgrade headers (shown above).

## Firewall

```bash
# ufw example — only SSH + HTTPS
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw enable
```

Do **not** publish `8080` on the public interface.

## Rate limiting (invite / login)

Protect `POST /auth/login`, `POST /auth/register`, and `POST /families/join` at the proxy:

**Caddy** (module or request body limits) / **nginx**:

```nginx
limit_req_zone $binary_remote_addr zone=benito_auth:10m rate=5r/m;

location ~ ^/(auth/|families/join) {
    limit_req zone=benito_auth burst=10 nodelay;
    proxy_pass http://127.0.0.1:8080;
    # ... same proxy headers as above
}
```

App-level rate limits can land later; proxy limits are enough for a family deploy.

## Clients

Set the iOS **Server URL** to `https://benito.example.com` (no trailing slash required).
