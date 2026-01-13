#!/usr/bin/env bash
set -euo pipefail

cd papermc

: "${MC_VERSION:=latest}"
: "${PAPER_BUILD:=latest}"
: "${PAPER_CHANNEL:=STABLE}"
: "${PAPER_PROJECT:=paper}"
: "${PAPER_UA:=oeschme-docker/1.0 (devnull@oesch.me)}"

MC_VERSION="${MC_VERSION,,}"
PAPER_BUILD="${PAPER_BUILD,,}"
PAPER_CHANNEL="${PAPER_CHANNEL^^}"
PAPER_PROJECT="${PAPER_PROJECT,,}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }
}
need_cmd jq
need_cmd curl

API_BASE="https://fill.papermc.io/v3/projects/${PAPER_PROJECT}"

curl_json() {
  curl -fsSL -H "User-Agent: ${PAPER_UA}" "$1"
}

die_api_if_error() {
  if echo "$1" | jq -e 'type=="object" and .ok == false' >/dev/null 2>&1; then
    echo "API error: $(echo "$1" | jq -r '.message // "Unknown error"')" >&2
    exit 1
  fi
}

build_list_jq='
  (if type=="array" then .
   elif type=="object" and has("builds") then .builds
   elif type=="object" and has("data") then .data
   else []
   end)
'

get_latest_for_channel() {
  # args: json channel
  local json="$1"
  local ch="$2"

  echo "$json" | jq -r --arg ch "$ch" "
    first( $build_list_jq[]?
      | select(type==\"object\" and .channel == \$ch)
      | [
          (.downloads[\"server:default\"].url // \"\"),
          (.downloads[\"server:default\"].name // \"\"),
          (.downloads[\"server:default\"].checksums.sha256 // \"\"),
          ((.id // .build // \"\")|tostring)
        ] | @tsv
    ) // \"\"
  "
}

get_specific_build() {
  # args: json build_id
  local json="$1"
  local id="$2"

  echo "$json" | jq -r --arg id "$id" "
    first( $build_list_jq[]?
      | select(type==\"object\" and ((.id // .build // \"\")|tostring) == \$id)
      | [
          (.downloads[\"server:default\"].url // \"\"),
          (.downloads[\"server:default\"].name // \"\"),
          (.downloads[\"server:default\"].checksums.sha256 // \"\"),
          ((.id // .build // \"\")|tostring)
        ] | @tsv
    ) // \"\"
  "
}

if [[ "$MC_VERSION" == "latest" ]]; then
  proj_json="$(curl_json "${API_BASE}")"
  die_api_if_error "$proj_json"
  MC_VERSION="$(echo "$proj_json" | jq -r '.versions | to_entries[0] | .value[0]')"
fi

builds_json="$(curl_json "${API_BASE}/versions/${MC_VERSION}/builds")"
die_api_if_error "$builds_json"

download_url=""
download_name=""
download_sha256=""

if [[ "$PAPER_BUILD" == "latest" ]]; then
  row="$(get_latest_for_channel "$builds_json" "$PAPER_CHANNEL" || true)"

  if [[ -n "${row:-}" ]]; then
    IFS=$'\t' read -r download_url download_name download_sha256 PAPER_BUILD <<<"$row"
  fi

  if [[ -z "${download_url:-}" ]]; then
    echo "No ${PAPER_CHANNEL} build found for MC ${MC_VERSION}. Searching newer versions for a ${PAPER_CHANNEL} build..." >&2

    versions_json="$(curl_json "${API_BASE}")"
    die_api_if_error "$versions_json"
    mapfile -t versions < <(echo "$versions_json" | jq -r '.versions | to_entries[] | .value[]' | sort -V -r)

    found="false"
    for ver in "${versions[@]}"; do
      ver_builds_json="$(curl_json "${API_BASE}/versions/${ver}/builds")"
      die_api_if_error "$ver_builds_json"

      row="$(get_latest_for_channel "$ver_builds_json" "$PAPER_CHANNEL" || true)"
      if [[ -n "${row:-}" ]]; then
        IFS=$'\t' read -r download_url download_name download_sha256 PAPER_BUILD <<<"$row"
        MC_VERSION="$ver"
        builds_json="$ver_builds_json"
        found="true"
        break
      fi
    done

    if [[ "$found" != "true" ]]; then
      echo "No ${PAPER_CHANNEL} builds available for any version." >&2
      exit 1
    fi
  fi
else
  row="$(get_specific_build "$builds_json" "$PAPER_BUILD" || true)"
  if [[ -n "${row:-}" ]]; then
    IFS=$'\t' read -r download_url download_name download_sha256 PAPER_BUILD <<<"$row"
  fi

  if [[ -z "${download_url:-}" ]]; then
    echo "Build ${PAPER_BUILD} not found for MC ${MC_VERSION}." >&2
    exit 1
  fi
fi

if [[ -z "${download_url:-}" ]]; then
  echo "Could not resolve a download URL (mc=${MC_VERSION}, channel=${PAPER_CHANNEL}, build=${PAPER_BUILD})." >&2
  exit 1
fi

JAR_NAME="paper-${MC_VERSION}-${PAPER_BUILD}.jar"

should_download="true"
if [[ -f "$JAR_NAME" && -n "${download_sha256:-}" ]] && command -v sha256sum >/dev/null 2>&1; then
  local_sha="$(sha256sum "$JAR_NAME" | awk '{print $1}')"
  if [[ "$local_sha" == "$download_sha256" ]]; then
    should_download="false"
  fi
fi

if [[ "$should_download" == "true" ]]; then
  rm -f ./*.jar
  echo "Downloading ${download_name:-$JAR_NAME} (MC ${MC_VERSION}, build ${PAPER_BUILD}, channel ${PAPER_CHANNEL})"
  curl -fL -H "User-Agent: ${PAPER_UA}" -o "$JAR_NAME" "$download_url"

  if [[ -n "${download_sha256:-}" ]] && command -v sha256sum >/dev/null 2>&1; then
    echo "${download_sha256}  ${JAR_NAME}" | sha256sum -c -
  fi
else
  echo "Jar is up-to-date (SHA256 matches latest ${PAPER_CHANNEL} build)."
fi

echo "eula=${EULA:-false}" > eula.txt

if [[ -n "${MC_RAM:-}" ]]; then
  if [[ -n "${MC_RAM_MIN:-}" ]]; then
    JAVA_OPTS="-Xms${MC_RAM_MIN} -Xmx${MC_RAM} ${JAVA_OPTS:-}"
  else
    JAVA_OPTS="-Xms${MC_RAM} -Xmx${MC_RAM} ${JAVA_OPTS:-}"
  fi
fi

exec java -server ${JAVA_OPTS:-} -jar "$JAR_NAME" --nogui