# PaperMC Docker

Standalone Docker image for [PaperMC](https://papermc.io), also usable by an explicitly enrolled PaperPilot server adapter. Originally forked from [phyremaster/papermc](https://hub.docker.com/r/phyremaster/papermc); the startup script has since been rewritten.

- Image: https://hub.docker.com/r/oeschme/papermc
- Source: https://github.com/OeschMe/papermc
- Runtime: Alpine 3.23, OpenJDK 25, Bash/curl/jq. Platforms: linux/amd64 and linux/arm64, tested natively before publishing.
- Version 1.2.0: safe explicit version selection, verified atomic downloads, retained JARs, optional offline startup and automated boot/restart tests.

## Standalone use

Choose a Minecraft version and exact stable Paper build from the [official downloads service](https://docs.papermc.io/misc/downloads-service/). Example tested target: Minecraft 26.3, Paper build 226. Review and accept the [Minecraft EULA](https://www.minecraft.net/eula) before setting `EULA=true`.

```yaml
services:
  minecraft:
    image: oeschme/papermc:1.2.0
    environment:
      EULA: "true"
      MC_VERSION: "26.3"
      PAPER_BUILD: "226"
      PAPER_CHANNEL: "STABLE"
      MC_RAM: "4G"
      MC_RAM_MIN: "1G"
    ports:
      - "25565:25565/tcp"
    volumes:
      - minecraft-data:/papermc
    restart: unless-stopped
    stop_grace_period: 60s
volumes:
  minecraft-data:
```

Save as `compose.yml`, then run `docker compose up -d`. Existing-server operators must keep their current world/plugin mounts, ports, networks and configuration owner; this example is not permission to replace a running deployment. Environment changes require container recreation, e.g. `docker compose up -d` after editing the source configuration, rather than only a restart.

Default process UID remains root for compatibility with existing volume ownership. For an unprivileged standalone run, specify `user: "<uid>:<gid>"` and prepare the data directory with matching ownership/write access. The image does not recursively chown existing server data, install a controller or mount the Docker socket.

## Environment contract

| Variable | Default | Meaning |
|---|---|---|
| `MC_VERSION` | `latest` | Explicit MC version, or newest version with a build in the selected channel. Exact pins are recommended. |
| `PAPER_BUILD` | `latest` | Exact positive build number or greatest numeric build ID in the selected MC version/channel. Exact build requires explicit MC version. |
| `PAPER_CHANNEL` | `STABLE` | Required channel for **both** latest and exact build selection. Set deliberately to use nonstable builds. |
| `PAPER_PROJECT` | `paper` | Official Paper Downloads project ID. Defaults/tests/documented compatibility target Paper; other projects are not promised production support. |
| `PAPER_UA` | Project-identifying User-Agent with this source URL | Sent to the Paper service and download requests. May be replaced with an identifying operator contact. |
| `EULA` | `false` | Only `true` explicitly permits startup. A refusal happens before download/world changes. |
| `MC_RAM` | empty | Maximum Java heap; also minimum heap if `MC_RAM_MIN` is unset. Empty leaves JVM defaults. |
| `MC_RAM_MIN` | empty | Minimum heap; ignored unless `MC_RAM` is supplied. Sizes are positive integers with optional K/M/G suffix. |
| `JAVA_OPTS` | empty | Whitespace-delimited extra JVM arguments. Shell syntax, quoting and glob expansion are not evaluated. Do not put secrets in arguments. |
| `PAPER_DATA_DIR` | `/papermc` | Existing writable absolute data directory. Mount that directory if overriding it; `/papermc` remains the image's declared volume. |
| `PAPER_OFFLINE` | `false` | `true` requires exact version/build, an image-generated cache manifest and a matching local SHA-256; makes no Paper API/download requests. |

### Online startup and retained artifacts

With `PAPER_OFFLINE=false`, startup checks the official v3 API even when a JAR is cached. A matching SHA-256 avoids redownloading. Downloads require the official HTTPS artifact host and SHA-256, use bounded timeouts/retries/size limits, and are verified in a temporary file **before** atomic replacement of the target JAR. Redirects are not followed. Failed downloads/checksums preserve existing JARs.

**An explicit Minecraft version never falls back to another version.** If its requested channel/build is unavailable, startup stops with an error. `MC_VERSION=latest` is the explicit cross-version discovery option: a restart can select a newer stable Minecraft version. Do not use latest selections for controlled production upgrades.

Old and unrelated top-level JARs are preserved, as are plugin/world/config directories. Retained JARs consume disk space; remove obsolete artifacts only through your own reviewed retention policy. The image performs no world pruning, plugin upgrade, BlueMap purge, backup or automatic rollback.

### Verified offline restarts

A successful online startup records `.paper-cache/<project>-<version>-<build>.json` beside the JAR. After that, the same exact pins with `PAPER_OFFLINE=true` verify the cached JAR locally and start without querying/downloading from Paper. Missing/mismatched manifests, channel changes or corrupted JARs fail closed. Unverified old JARs do not count as offline cache.

This is an integrity cache owned by the data-directory owner, not an authorization mechanism or signed provenance. Do not edit the manifest to bypass validation. Paperclip's first boot downloads its runtime/libraries; fully network-isolated boot therefore also needs a previously completed boot/cache. Plugins and server features may independently need network access.

A data-directory lock is held for the Java process lifetime, preventing two copies of this entrypoint from starting against the same directory. Java receives signals directly via `exec`; allow enough stop grace time to save worlds. Do not run two independently launched server processes against the same world.

## With PaperPilot

PaperPilot is a separate manager, not a requirement or a bundled image feature. Both standalone and managed deployments use the same environment/startup contract; there is no silent auto-enrollment or management takeover.

The manager must first verify the **running image digest**, persisted Compose/Portainer source, mounts and supported contract. It must pin exact MC version/build/channel, preserve unrelated settings and require its own backup/approval/controller gates before recreating the enrolled server. After initial verified boot it can explicitly select offline startup for reproducible pinned restarts. Scheduled release checks never change these variables or deploy anything. This image update alone does not implement PaperPilot's adapter or authorize modifying any production deployment.

## Testing and releases

```sh
bash -n paper.sh
shellcheck paper.sh tests/smoke.sh
python3 -m unittest discover -s tests -v
docker build -t papermc:test .
bash tests/smoke.sh papermc:test
```

Host test prerequisites: Linux Bash, Python 3, jq, curl, flock and Docker for image/real-server smoke tests. Unit tests replace curl/Java with fakes and use temporary directories. The Docker smoke test creates its own volume/container, publishes no host ports, boots a real pinned server, stops it gracefully, then boots the same target with networking disabled and verifies shutdown. Never point tests at production resources.

GitHub CI runs shell checks, hermetic tests and real image/boot/restart tests on native x86-64 and ARM64 runners. Publishing is a separate manual **Publish Docker image** workflow, gated by the same tests. Add a write-capable Docker Hub token as repository secret `DOCKERHUB_TOKEN`; the workflow uses Docker ID `oeschme`. Select the matching semantic version and whether to update `latest`. It builds/pushes both architectures with source revision, provenance and SBOM metadata. Source publication is not proof of image delivery: verify the finished workflow and registry digest.

## Migration from 1.1.1

- Keep your existing `/papermc` data mount and established Compose/Portainer owner. No production migration is performed by publishing this image.
- Exact build selection now enforces its channel. Explicit MC versions no longer silently switch to another version when no channel match exists.
- Missing/invalid published SHA-256 is fatal. Downloads preserve old JARs and no longer clear all top-level JARs.
- Explicit `EULA=true` is required before downloading/starting. Existing `MC_RAM`, `MC_RAM_MIN` and whitespace-delimited `JAVA_OPTS` behavior is preserved.
- The default command is now an absolute `/paper.sh`, avoiding working-directory dependence. Existing root `/paper.sh` invocation remains available. Remove an obsolete custom command only after reviewing your deployment.
- Offline mode is opt-in and needs the new cache manifest plus previously populated runtime cache. It is not automatically enabled for existing installations.
- Alpine is pinned to the 3.23 release series; Java remains version 25. Image builds still receive package/security updates within that series; record the published image digest for exact deployment reproducibility.
