#!/usr/bin/env bash
set -euo pipefail

# Standalone image contract. PaperPilot must enroll and pin a target explicitly.
: "${MC_VERSION:=latest}"
: "${PAPER_BUILD:=latest}"
: "${PAPER_CHANNEL:=STABLE}"
: "${PAPER_PROJECT:=paper}"
: "${PAPER_UA:=oeschme-papermc/1.2.0 (https://github.com/OeschMe/papermc)}"
: "${PAPER_DATA_DIR:=/papermc}"
: "${PAPER_OFFLINE:=false}"

fail() { echo "PaperMC: $*" >&2; exit 1; }
for tool in curl jq sha256sum flock java; do
  command -v "$tool" >/dev/null 2>&1 || fail "Missing dependency: $tool"
done

MC_VERSION="${MC_VERSION,,}"
PAPER_BUILD="${PAPER_BUILD,,}"
PAPER_CHANNEL="${PAPER_CHANNEL^^}"
PAPER_PROJECT="${PAPER_PROJECT,,}"
PAPER_OFFLINE="${PAPER_OFFLINE,,}"
[[ "$MC_VERSION" =~ ^[0-9]+(\.[0-9]+)*(-[a-z0-9][a-z0-9.-]*)?$ || "$MC_VERSION" == latest ]] || fail "Invalid MC_VERSION"
[[ "$PAPER_BUILD" =~ ^[1-9][0-9]*$ || "$PAPER_BUILD" == latest ]] || fail "PAPER_BUILD must be a positive build number or latest"
[[ "$PAPER_CHANNEL" =~ ^[A-Z][A-Z0-9_]*$ ]] || fail "Invalid PAPER_CHANNEL"
[[ "$PAPER_PROJECT" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "Invalid PAPER_PROJECT"
[[ "$PAPER_OFFLINE" == true || "$PAPER_OFFLINE" == false ]] || fail "PAPER_OFFLINE must be true or false"
[[ "${EULA:-false}" == true ]] || fail "Accept the Minecraft EULA explicitly with EULA=true"
[[ "$PAPER_DATA_DIR" == /* && -d "$PAPER_DATA_DIR" && -w "$PAPER_DATA_DIR" ]] || fail "PAPER_DATA_DIR must be an existing writable absolute directory"
[[ "$PAPER_UA" != *$'\n'* && "$PAPER_UA" != *$'\r'* ]] || fail "Invalid PAPER_UA"
if [[ "$MC_VERSION" == latest && "$PAPER_BUILD" != latest ]]; then
  fail "An exact PAPER_BUILD requires an explicit MC_VERSION"
fi
if [[ "$PAPER_OFFLINE" == true && ( "$MC_VERSION" == latest || "$PAPER_BUILD" == latest ) ]]; then
  fail "Offline startup requires exact MC_VERSION and PAPER_BUILD pins"
fi
for value in "${MC_RAM:-}" "${MC_RAM_MIN:-}"; do
  [[ -z "$value" || "$value" =~ ^[1-9][0-9]*[kKmMgG]?$ ]] || fail "Invalid heap size"
done

cd -- "$PAPER_DATA_DIR"
[[ ! -L .paper.lock && ! -L .paper-cache ]] || fail "Lock/cache paths must not be symlinks"
exec 9>.paper.lock
flock -n 9 || fail "Another server already owns this data directory"
mkdir -p .paper-cache
partial=""
manifest_tmp=""
cleanup() {
  [[ -z "$partial" ]] || rm -f -- "$partial"
  [[ -z "$manifest_tmp" ]] || rm -f -- "$manifest_tmp"
}
trap cleanup EXIT

api_base="https://fill.papermc.io/v3/projects/${PAPER_PROJECT}"
api() {
  curl --fail --silent --show-error --proto '=https' --tlsv1.2 \
    --connect-timeout 15 --max-time 60 --retry 2 --retry-delay 1 --retry-max-time 120 \
    --max-filesize 8388608 -H "User-Agent: ${PAPER_UA}" "$1"
}
# Handle current v3 arrays plus its documented wrapper variants. Malformed/error
# objects fail closed; an empty valid list is handled by the selection logic.
normalize='if type == "array" then . elif type == "object" and (.builds|type) == "array" then .builds elif type == "object" and (.data|type) == "array" then .data else error("Invalid Paper builds response") end'
select_build() {
  jq -ce --arg channel "$PAPER_CHANNEL" --arg build "$PAPER_BUILD" "$normalize"' |
    [.[] | select(.channel == $channel) |
      select((.id | type) == "number" and (.id | floor) == .id and .id > 0) |
      select($build == "latest" or (.id | tostring) == $build)] |
    sort_by(.id) | if length == 0 then null else .[-1] end'
}

if [[ "$PAPER_OFFLINE" == true ]]; then
  jar_name="${PAPER_PROJECT}-${MC_VERSION}-${PAPER_BUILD}.jar"
  cache=".paper-cache/${PAPER_PROJECT}-${MC_VERSION}-${PAPER_BUILD}.json"
  [[ -f "$cache" && ! -L "$cache" && -f "$jar_name" && ! -L "$jar_name" ]] || fail "No verified offline cache for the pinned target"
  download_sha256="$(jq -er --arg project "$PAPER_PROJECT" --arg version "$MC_VERSION" --arg build "$PAPER_BUILD" --arg channel "$PAPER_CHANNEL" \
    'select(.project == $project and .version == $version and .build == $build and .channel == $channel) | .sha256 | select(type == "string" and test("^[a-f0-9]{64}$"))' "$cache")" || fail "Offline cache metadata does not match the pins/channel"
  [[ "$(sha256sum "$jar_name" | cut -d ' ' -f 1)" == "$download_sha256" ]] || fail "Offline JAR checksum mismatch"
  echo "Starting verified offline target: ${MC_VERSION} build ${PAPER_BUILD} (${PAPER_CHANNEL})"
else
  if [[ "$MC_VERSION" == latest ]]; then
    project_json="$(api "$api_base")" || fail "Cannot fetch Paper version list"
    version_text="$(jq -er '.versions | objects | [.[] | arrays | .[] | strings] | if length == 0 then error("No versions") else .[] end' <<<"$project_json")" || fail "Invalid Paper version list"
    mapfile -t versions < <(printf '%s\n' "$version_text" | sort -V -r -u)
  else
    versions=("$MC_VERSION")
  fi
  selected=""
  for version in "${versions[@]}"; do
    [[ "$version" =~ ^[0-9]+(\.[0-9]+)*(-[a-z0-9][a-z0-9.-]*)?$ ]] || fail "Invalid version in Paper response"
    builds_json="$(api "${api_base}/versions/${version}/builds")" || fail "Cannot fetch builds for ${version}"
    selected="$(select_build <<<"$builds_json")" || {
      # jq -e returns 1 for a valid null; malformed responses have another status.
      status=$?
      [[ "$status" == 1 ]] || fail "Invalid Paper build metadata"
      selected=""
    }
    if [[ -n "$selected" && "$selected" != null ]]; then
      MC_VERSION="$version"
      break
    fi
  done
  [[ -n "$selected" && "$selected" != null ]] || fail "No ${PAPER_CHANNEL} build matches the requested MC version/build; no version fallback for explicit pins"
  PAPER_BUILD="$(jq -er '.id | tostring' <<<"$selected")"
  download_url="$(jq -er '.downloads["server:default"].url | strings' <<<"$selected")" || fail "Missing artifact URL"
  download_sha256="$(jq -er '.downloads["server:default"].checksums.sha256 | strings | select(test("^[a-f0-9]{64}$"))' <<<"$selected")" || fail "Missing/invalid SHA-256; refusing an unverified download"
  [[ "$download_url" =~ ^https://fill-data\.papermc\.io/[^[:space:]]+$ ]] || fail "Artifact host must be fill-data.papermc.io over HTTPS"
  jar_name="${PAPER_PROJECT}-${MC_VERSION}-${PAPER_BUILD}.jar"
  [[ ! -L "$jar_name" ]] || fail "Target JAR must not be a symlink"
  if [[ ! -f "$jar_name" || "$(sha256sum "$jar_name" | cut -d ' ' -f 1)" != "$download_sha256" ]]; then
    partial="$(mktemp '.paper-download.XXXXXXXX')"
    echo "Downloading ${PAPER_PROJECT} ${MC_VERSION} build ${PAPER_BUILD} (${PAPER_CHANNEL})"
    # No redirects: a changed host/redirect must be reviewed, not followed blindly.
    curl --fail --silent --show-error --proto '=https' --tlsv1.2 \
      --connect-timeout 15 --max-time 300 --retry 2 --retry-delay 1 --retry-max-time 600 \
      --max-filesize 536870912 -H "User-Agent: ${PAPER_UA}" -o "$partial" "$download_url" || fail "Artifact download failed; existing JARs preserved"
    [[ "$(sha256sum "$partial" | cut -d ' ' -f 1)" == "$download_sha256" ]] || fail "Artifact checksum mismatch; existing JARs preserved"
    mv -f -- "$partial" "$jar_name"
    partial=""
  fi
  manifest_tmp="$(mktemp '.paper-cache/.manifest.XXXXXXXX')"
  jq -n --arg project "$PAPER_PROJECT" --arg version "$MC_VERSION" --arg build "$PAPER_BUILD" --arg channel "$PAPER_CHANNEL" --arg sha256 "$download_sha256" \
    '{project:$project,version:$version,build:$build,channel:$channel,sha256:$sha256}' > "$manifest_tmp"
  mv -f -- "$manifest_tmp" ".paper-cache/${PAPER_PROJECT}-${MC_VERSION}-${PAPER_BUILD}.json"
  manifest_tmp=""
fi

# Keep old JARs for rollback; never remove unrelated JARs, worlds or plugin data.
printf 'eula=true\n' > eula.txt
java_args=(-server)
if [[ -n "${MC_RAM:-}" ]]; then
  java_args+=("-Xms${MC_RAM_MIN:-$MC_RAM}" "-Xmx${MC_RAM}")
fi
# Legacy JAVA_OPTS remains whitespace-delimited; never eval it as shell code.
extra_args=()
read -r -a extra_args <<< "${JAVA_OPTS:-}"
exec java "${java_args[@]}" "${extra_args[@]}" -jar "$jar_name" --nogui
