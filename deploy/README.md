# Docker deployment

This deployment ships Open Design as a single Debian-slim-based runtime image. The
daemon serves both the API and the built Next.js static export, so there is no
separate nginx container.

## Local compose

Before starting:

1. Copy the environment template:

   ```bash
   cp .env.example .env
   ```

2. Generate a secure token:

   ```bash
   openssl rand -hex 32
   ```

3. Open `.env` in your editor, find `OD_API_TOKEN=`, and paste the generated token there.

Then pull and start the service:

```bash
OPEN_DESIGN_IMAGE=docker.io/vanjayak/open-design:latest docker compose pull
OPEN_DESIGN_IMAGE=docker.io/vanjayak/open-design:latest docker compose up -d --no-build
```

Defaults:

- Host port: `127.0.0.1:7456` (`OPEN_DESIGN_PORT=8080` to publish on `127.0.0.1:8080`)
- Runtime data volume: `open_design_data` mounted at `/app/.od`
- Node heap cap: `--max-old-space-size=192`
- Compose memory cap: `384m` (`OPEN_DESIGN_MEM_LIMIT=256m` to override)

Do not publish the daemon directly on a public or shared LAN interface. The API is
unauthenticated for non-browser clients, so remote deployments should keep Compose
bound to localhost and put an authenticated reverse proxy, SSH tunnel, or VPN in
front of it.

When exposing the service through an authenticated public IP, domain, or reverse
proxy, set `OPEN_DESIGN_ALLOWED_ORIGINS` to the browser origins that should be
allowed to call `/api`:

```bash
OPEN_DESIGN_ALLOWED_ORIGINS=https://od.example.com,http://203.0.113.10:7456 docker compose up -d --no-build
```

Pin a specific published image with a digest instead of the mutable `latest` tag:

```bash
OPEN_DESIGN_IMAGE=docker.io/vanjayak/open-design@sha256:<digest> docker compose up -d --no-build
```

## Offline rebuilds

The production image is intentionally runtime-only. It contains the deployed
daemon's production `node_modules`, but not the workspace source, TypeScript,
pnpm store, or a writable filesystem. It cannot compile code after startup.

The GitHub Actions `Docker image` workflow exports a separate
`open-design-offline-builder-linux-amd64-<sha>` artifact. Download that artifact
from a connected machine, transfer the `.tar` file to the offline server, then
load it there:

```bash
docker load -i open-design-offline-builder-linux-amd64.tar
```

For source-only changes (no changes to `package.json` or `pnpm-lock.yaml`), mount
the changed workspace directories over the builder image. The image retains the
matching pnpm store and complete development dependency graph. The offline
install recreates package-local `node_modules` hidden by those bind mounts; it
fails rather than reaching the package registry if anything is missing:

```bash
docker run --rm \
  -v "$PWD/apps:/app/apps" \
  -v "$PWD/packages:/app/packages" \
  -v "$PWD/tools:/app/tools" \
  -v "$PWD/deploy:/app/deploy" \
  ghcr.io/<owner>/od:offline-builder-<commit-sha> \
  sh -lc 'pnpm --offline install --frozen-lockfile && \
    pnpm --offline --filter @open-design/daemon... run build && \
    pnpm --offline --filter @open-design/daemon deploy --legacy --prod /app/deploy/daemon && \
    pnpm --offline --filter @open-design/web build'
```

The resulting artifacts are written to the mounted host paths:

- `deploy/daemon/`
- `apps/web/out/`

To run those artifacts with the normal runtime image, apply the optional
Compose overlay and recreate the service:

```bash
docker compose \
  -f deploy/docker-compose.yml \
  -f deploy/docker-compose.offline-build.yml \
  up -d --force-recreate
```

The overlay mounts only the compiled daemon and static web export as read-only
paths. Remove its second `-f` argument to return to the artifacts bundled in
the published runtime image.

Use a builder archive generated from the same commit as the unchanged lockfile.
If a dependency declaration or lockfile changes, rebuild the offline-builder
image on a connected runner and transfer its new archive; do not attempt an
offline dependency install with the old image.
The image intentionally does not bundle Claude/Codex/Gemini CLI binaries. Keep
those outside the image, or build a separate private runtime layer if a server
deployment needs local code-agent CLIs installed in the container.

If you install Codex inside an unprivileged Linux container and it fails while
creating its `workspace-write` sandbox, opt into Codex's full-access mode for
all Codex runs in that deployment:

```bash
OD_CODEX_SANDBOX=danger-full-access docker compose up -d --no-build
```

Only the exact value `danger-full-access` is supported; unknown values are
ignored. Use this only for trusted, single-user deployments. It lets Codex run
without the workspace-write sandbox, which is useful when the container host
blocks unprivileged user namespaces, but it gives the Codex process broader
filesystem access inside the container.

## Publish to Docker Hub

```bash
deploy/scripts/publish-images.sh --image_tag latest
```

Useful overrides:

```bash
IMAGE_NAMESPACE=your-dockerhub-user deploy/scripts/publish-images.sh --arch arm64
deploy/scripts/publish-images.sh --image docker.io/your-user/open-design:0.1.0
```

The script defaults to:

- `docker.io/vanjayak/open-design:<tag>`
- `linux/amd64,linux/arm64`
- `skopeo` push strategy with Docker credentials read from `~/.docker/config.json`
- preloading base images through `skopeo` to reduce Docker Hub pull flakiness

If `127.0.0.1:7890` is available and no proxy is already set, the script uses it
for registry access and passes `host.docker.internal:7890` into Docker builds. The
host-gateway alias is only added for builds that need this local proxy mapping.

### Colima swap helper for Apple Silicon

`deploy/scripts/prepare-colima-build-swap.sh` is for manual Docker image
publishing from an Apple Silicon macOS host that uses Colima as the Docker VM.
The helper is intentionally Apple Silicon-only because the failure mode it covers
is local arm64 Colima builds exhausting a small Linux VM while preparing
multi-arch images. It exits before touching Colima on non-macOS or
non-Apple-Silicon hosts.

Low-memory Colima VMs can run out of RAM during multi-arch image builds. The
helper checks the VM memory and swap status, then creates and enables a temporary
swap file only when the VM has no swap and less than 4 GiB of RAM. The 4 GiB
threshold is a conservative default for short-lived manual publishes on small
Colima profiles; raise `COLIMA_BUILD_SWAP_MEMORY_THRESHOLD_KIB` if larger builds
still OOM, or lower it if you only want swap for very small VMs.

Prefer increasing the Colima VM memory (`colima start --memory <GiB>` or the
profile config) when you want a persistent build machine. Use this helper when
you need a temporary, reversible boost for one manual publish without resizing
or recreating the VM.

Run it before a manual publish if Docker builds fail with out-of-memory errors,
or if `status` shows a small Colima VM with no swap. The swap remains active
until cleanup or VM restart, so use a shell trap for one-off sessions:

```bash
deploy/scripts/prepare-colima-build-swap.sh status
deploy/scripts/prepare-colima-build-swap.sh
trap 'deploy/scripts/prepare-colima-build-swap.sh cleanup' EXIT
deploy/scripts/publish-images.sh --image_tag latest
```

Useful overrides:

```bash
COLIMA_BUILD_SWAP_SIZE=6G deploy/scripts/prepare-colima-build-swap.sh
COLIMA_BUILD_SWAP_MEMORY_THRESHOLD_KIB=6291456 deploy/scripts/prepare-colima-build-swap.sh
COLIMA_BIN=/opt/homebrew/bin/colima deploy/scripts/prepare-colima-build-swap.sh status
COLIMA_BUILD_SWAP_CLEANUP_FORCE=1 COLIMA_BUILD_SWAPFILE=/custom-swapfile deploy/scripts/prepare-colima-build-swap.sh cleanup
```

`cleanup` removes the default helper path and the old helper path. If you set a
custom `COLIMA_BUILD_SWAPFILE`, cleanup refuses to remove it unless
`COLIMA_BUILD_SWAP_CLEANUP_FORCE=1` is also set.
