FROM node:22-bookworm AS openclaw-build

# Install Bun (build script dependency)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /app

ARG OPENCLAW_GIT_REF=main

RUN git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" https://github.com/openclaw/openclaw.git .

RUN pnpm install --frozen-lockfile
RUN pnpm build

ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install && pnpm ui:build

FROM nikolaik/python-nodejs:python3.12-nodejs22-bookworm

ENV NODE_ENV=production
ENV PORT=6658

ARG TIGRISFS_VERSION=1.2.1

RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		fuse \
		ca-certificates \
		curl; \
	corepack enable pnpm; \
	curl -fsSL "https://github.com/tigrisdata/tigrisfs/releases/download/v${TIGRISFS_VERSION}/tigrisfs_${TIGRISFS_VERSION}_linux_amd64.deb" -o /tmp/tigrisfs.deb; \
	dpkg -i /tmp/tigrisfs.deb; \
	rm -f /tmp/tigrisfs.deb; \
	rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

COPY --from=openclaw-build /app /openclaw

RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/index.js "$@"' > /usr/local/bin/openclaw \
	&& chmod +x /usr/local/bin/openclaw

RUN install -m 755 /dev/stdin /entrypoint.sh <<'EOF'
#!/bin/bash
set -e

MOUNT_POINT="/data"

# State directory corresponds to ~/.openclaw (contains config, credentials, sessions)
# Workspace defaults to $OPENCLAW_STATE_DIR/workspace per docs
export OPENCLAW_STATE_DIR="$MOUNT_POINT"
export OPENCLAW_WORKSPACE_DIR="$MOUNT_POINT/workspace"

setup_workspace() {
	mkdir -p "$OPENCLAW_WORKSPACE_DIR"
}

reset_mountpoint() {
	mountpoint -q "$MOUNT_POINT" 2>/dev/null && fusermount -u "$MOUNT_POINT" 2>/dev/null || true
	rm -rf "$MOUNT_POINT"
	mkdir -p "$MOUNT_POINT"
}

reset_mountpoint

if [ -z "$S3_ENDPOINT" ] || [ -z "$S3_BUCKET" ] || [ -z "$S3_ACCESS_KEY_ID" ] || [ -z "$S3_SECRET_ACCESS_KEY" ]; then
	echo "[WARN] S3 configuration incomplete, using local directory mode"
else
	echo "[INFO] Mounting S3: ${S3_BUCKET} -> ${MOUNT_POINT}"

	export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
	export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
	export AWS_REGION="${S3_REGION:-auto}"
	export AWS_S3_PATH_STYLE="${S3_PATH_STYLE:-false}"

	/usr/bin/tigrisfs --endpoint "$S3_ENDPOINT" ${TIGRISFS_ARGS:-} -f "${S3_BUCKET}${S3_PREFIX:+:$S3_PREFIX}" "$MOUNT_POINT" &
	sleep 3

	if ! mountpoint -q "$MOUNT_POINT"; then
		echo "[ERROR] S3 mount failed"
		exit 1
	fi
	echo "[OK] S3 mounted successfully"
fi

setup_workspace

cleanup() {
	echo "[INFO] Shutting down..."
	if [ -n "$OPENCLAW_PID" ]; then
		kill -TERM "$OPENCLAW_PID" 2>/dev/null
		wait "$OPENCLAW_PID" 2>/dev/null
	fi
	if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
		fusermount -u "$MOUNT_POINT" 2>/dev/null || true
	fi
	exit 0
}
trap cleanup SIGTERM SIGINT

if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
	echo "[INFO] Using Gateway Token from environment variable"
else
	echo "[WARN] OPENCLAW_GATEWAY_TOKEN not set, will be auto-generated"
fi

cat > "$OPENCLAW_STATE_DIR/openclaw.json" << 'EOFCONFIG'
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "port": 6658,
    "auth": {
      "mode": "token"
    },
    "controlUi": {
      "allowInsecureAuth": true,
      "allowedOrigins": ["https://open-flare.millennials-post-covid.com"]
    }
  },
  "browser": {
    "enabled": true,
    "evaluateEnabled": true,
    "remoteCdpTimeoutMs": 120000,
    "remoteCdpHandshakeTimeoutMs": 60000,
    "attachOnly": true,
    "defaultProfile": "cloudflare",
    "profiles": {
      "cloudflare": {
        "cdpUrl": "${WORKER_URL}/cloudflare.browser/${OPENCLAW_GATEWAY_TOKEN}",
        "driver": "clawd",
        "color": "#FF4500"
      }
    }
  }
}
EOFCONFIG
echo "[INFO] Config file written (local mode + allowInsecureAuth)"

echo "[INFO] Starting OpenClaw Gateway..."
echo "[INFO] Visit Web UI for initial setup on first use"
cd "$OPENCLAW_WORKSPACE_DIR"

openclaw gateway --port 6658 --bind lan --allow-unconfigured &
OPENCLAW_PID=$!
wait $OPENCLAW_PID
EOF

WORKDIR /data/workspace
EXPOSE 6658

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
	CMD curl -f http://localhost:6658/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
