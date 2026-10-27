#!/usr/bin/env bash
# Disposable GitHub-runner-only test. No existing containers, mounts, or host ports.
set -euo pipefail
image="${1:-papermc:test}"
name="papermc-smoke-${GITHUB_RUN_ID:-$$}-${RANDOM}"
volume="${name}-data"
settings="$(mktemp)"
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
  rm -f -- "$settings"
}
trap cleanup EXIT
cat > "$settings" <<'PROPERTIES'
online-mode=false
level-type=minecraft:flat
generate-structures=false
view-distance=2
simulation-distance=2
max-players=1
spawn-protection=0
PROPERTIES
docker volume create "$volume" >/dev/null
wait_ready() {
  for ((attempt=0; attempt<120; attempt++)); do
    logs="$(docker logs "$name" 2>&1)"
    if grep -Fq 'Done (' <<< "$logs"; then
      grep -E 'Paper version.*26[.]3.*226' <<< "$logs"
      return 0
    fi
    if [[ "$(docker inspect --format '{{.State.Running}}' "$name")" != true ]]; then
      docker logs "$name"
      return 1
    fi
    sleep 2
  done
  docker logs "$name"
  echo 'Paper did not become ready before the smoke-test timeout' >&2
  return 1
}
docker create --name "$name" -i --mount "type=volume,source=$volume,target=/papermc" \
  -e EULA=true -e MC_VERSION=26.3 -e PAPER_BUILD=226 -e MC_RAM=2G -e MC_RAM_MIN=512M \
  "$image" >/dev/null
docker cp "$settings" "$name:/papermc/server.properties"
docker start "$name" >/dev/null
wait_ready
docker stop --time 45 "$name" >/dev/null
exit_code="$(docker inspect --format '{{.State.ExitCode}}' "$name")"
[[ "$exit_code" == 0 || "$exit_code" == 143 ]]
docker logs "$name" 2>&1 | grep -E 'All dimensions are saved|All chunks are saved'
docker rm "$name" >/dev/null
# The second launch must boot the same cached target with networking unavailable.
docker run -d -i --name "$name" --network none \
  --mount "type=volume,source=$volume,target=/papermc" \
  -e EULA=true -e MC_VERSION=26.3 -e PAPER_BUILD=226 -e PAPER_OFFLINE=true \
  -e MC_RAM=2G -e MC_RAM_MIN=512M "$image" >/dev/null
wait_ready
docker logs "$name" 2>&1 | grep -F 'Starting verified offline target: 26.3 build 226'
docker stop --time 45 "$name" >/dev/null
exit_code="$(docker inspect --format '{{.State.ExitCode}}' "$name")"
[[ "$exit_code" == 0 || "$exit_code" == 143 ]]
docker logs "$name" 2>&1 | grep -E 'All dimensions are saved|All chunks are saved'
echo 'Disposable boot and offline restart passed; no production resources used.'
