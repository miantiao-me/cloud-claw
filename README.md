# Cloud Claw (Cloudflare + OpenClaw) 

**Cloud Claw** is a containerized AI assistant that runs [OpenClaw](https://github.com/openclaw/openclaw) on Cloudflare Workers + Containers.

A Worker handles routing and auth, forwards requests to a singleton container running an OpenClaw gateway instance, and proxies Chrome DevTools Protocol (CDP) sessions via Cloudflare Browser Rendering.

English | [简体中文](README.zh-CN.md)

---

## Tech Stack

- **Runtime**: Cloudflare Workers + Containers
- **Language**: TypeScript (ES2024)
- **Package Manager**: pnpm
- **Container Specs**: 1 vCPU, 4GB RAM, 8GB disk
- **Browser**: Cloudflare Browser Rendering (remote CDP)
- **Core Libraries**:
  - `cloudflare:workers`: Workers standard library
  - `@cloudflare/containers`: Container management
- **Container Base**: `nikolaik/python-nodejs:python3.12-nodejs22-bookworm`
- **Storage**: TigrisFS for S3/R2 mounting

## Quick Start

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/miantiao-me/cloud-claw)

### Prerequisites

- Node.js (v22+)
- pnpm (v10.28.2+)
- Wrangler CLI (`npm i -g wrangler`)

### Install Dependencies

```bash
pnpm install
```

### Local Development

Start the local development server:

```bash
pnpm dev
```

### Linting

Run formatter (oxfmt) and linter (oxlint):

```bash
pnpm lint
```

### Generate Type Definitions

If you modify bindings in `wrangler.jsonc`, regenerate the type file:

```bash
pnpm cf-typegen
```

## Deployment

Deploy code to Cloudflare's global network:

```bash
pnpm deploy
```

## Project Structure

```
.
├── src/
│   ├── index.ts        # Workers entry point, routing, basic auth
│   ├── container.ts    # AgentContainer class (extends Container), WebSocket gateway
│   └── cdp.ts          # Chrome DevTools Protocol proxy (chunked binary WebSocket framing)
├── Dockerfile          # Container image: OpenClaw gateway + TigrisFS S3 mount
├── worker-configuration.d.ts # Auto-generated Cloudflare binding types (DO NOT EDIT)
├── wrangler.jsonc      # Wrangler configuration (containers, bindings, placement)
├── tsconfig.json       # TypeScript configuration
└── package.json
```

## Data Persistence (S3/R2)

The container has built-in support for S3-compatible storage (such as Cloudflare R2, AWS S3). It uses `TigrisFS` to mount object storage as a local filesystem for persistent data storage.

### Environment Variables

To enable data persistence, configure the following environment variables in the container runtime environment:

| Variable                 | Description                                      | Required | Default |
| ------------------------ | ------------------------------------------------ | -------- | ------- |
| `S3_ENDPOINT`            | S3 API endpoint address                          | Yes      | -       |
| `S3_BUCKET`              | Bucket name                                      | Yes      | -       |
| `S3_ACCESS_KEY_ID`       | Access Key ID                                    | Yes      | -       |
| `S3_SECRET_ACCESS_KEY`   | Access Key Secret                                | Yes      | -       |
| `S3_REGION`              | Storage region                                   | No       | `auto`  |
| `S3_PATH_STYLE`          | Whether to use Path Style access                 | No       | `false` |
| `S3_PREFIX`              | Path prefix within the bucket (subdirectory)     | No       | (root)  |
| `TIGRISFS_ARGS`          | Additional mount arguments for TigrisFS          | No       | -       |
| `OPENCLAW_GATEWAY_TOKEN` | Gateway access token (for Web UI authentication) | Yes      | -       |
| `WORKER_URL`             | Worker's public URL (for CDP proxy config)       | Yes      | -       |

### How It Works

1. **Mount Point**: On container startup, the S3 bucket is mounted to `/data`.
2. **Workspace**: The actual workspace is located at `/data/workspace`.
3. **OpenClaw Config**: OpenClaw configuration files are stored in `/data/.openclaw` to ensure state persistence.
4. **Initialization**:
   - If the S3 bucket (or specified prefix path) is empty, the container automatically initializes the preset directory structure.
   - If S3 configuration is missing, the container falls back to non-persistent local directory mode.

### Web UI Initialization

After the first startup, OpenClaw needs to be initialized via the Web UI.
Visit the deployed URL (e.g., `https://your-worker.workers.dev`) and follow the on-screen instructions to complete setup.

## Browser Rendering (CDP Proxy)

Cloud Claw integrates [Cloudflare Browser Rendering](https://developers.cloudflare.com/browser-rendering/) to provide headless browser capabilities to the AI assistant via the Chrome DevTools Protocol (CDP).

### How It Works

1. **OpenClaw** connects to the Worker's CDP proxy endpoint (`/cloudflare.browser/{token}`) using WebSocket.
2. **The Worker** acquires a browser session from Cloudflare's Browser Rendering API and proxies CDP messages between OpenClaw and the remote browser.
3. **Binary framing**: CDP messages are chunked with a 4-byte length header to handle large payloads over Cloudflare's WebSocket infrastructure.

### Configuration

The CDP proxy is automatically configured when `WORKER_URL` and `OPENCLAW_GATEWAY_TOKEN` are set. The OpenClaw container generates a browser profile pointing to:

```
{WORKER_URL}/cloudflare.browser/{OPENCLAW_GATEWAY_TOKEN}
```

Authentication is handled via the token in the URL path — no additional setup required.

## Container Lifecycle

By default, the container automatically sleeps after 10 minutes of inactivity to save resources. You can customize this behavior:

### Keep Container Always Running

To prevent the container from sleeping, modify `src/container.ts`:

```typescript
export class AgentContainer extends Container {
  sleepAfter = 'never' // Never sleep (default: '10m')
  // ...
}
```

### Activity-Based Keep-Alive (Default)

The current implementation uses smart keep-alive: the container stays active during AI conversations and sleeps during idle periods. This is achieved by calling `renewActivityTimeout()` when chat events are received:

```typescript
// In watchContainer() - resets the sleep timer on each chat completion
if (frame.event === 'chat' && frame.payload?.state === 'final') {
  this.renewActivityTimeout()
}
```

### Available Options

| `sleepAfter` Value | Behavior                                       |
| ------------------ | ---------------------------------------------- |
| `'never'`          | Container runs indefinitely                    |
| `'10m'`            | Sleep after 10 minutes of inactivity (default) |
| `'1h'`             | Sleep after 1 hour of inactivity               |
| `'30s'`            | Sleep after 30 seconds of inactivity           |

> **Note**: When sleeping, the container state is preserved. It will automatically wake up on the next request, but cold start may take a few seconds.

## Development Guidelines

For detailed development guidelines, code style, and AI agent behavior standards, please refer to [AGENTS.md](./AGENTS.md).
