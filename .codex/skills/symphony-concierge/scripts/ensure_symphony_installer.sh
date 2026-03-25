#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

require_command() {
  local name="$1"

  if ! command -v "$name" >/dev/null 2>&1; then
    die "required command not found: $name"
  fi
}

normalize_os() {
  local uname_s
  uname_s="$(uname -s | tr '[:upper:]' '[:lower:]')"

  case "$uname_s" in
    darwin) echo "darwin" ;;
    linux) echo "linux" ;;
    *) die "unsupported OS: $uname_s (supported: darwin, linux)" ;;
  esac
}

normalize_arch() {
  local uname_m
  uname_m="$(uname -m | tr '[:upper:]' '[:lower:]')"

  case "$uname_m" in
    x86_64 | amd64) echo "x86_64" ;;
    arm64 | aarch64) echo "arm64" ;;
    *) die "unsupported architecture: $uname_m (supported: x86_64, arm64)" ;;
  esac
}

score_asset_name() {
  local asset_name="$1"
  local os="$2"
  local arch="$3"
  local score=0
  local lowered

  lowered="$(printf '%s' "$asset_name" | tr '[:upper:]' '[:lower:]')"

  if [[ "$lowered" == *"symphony"* ]]; then
    score=$((score + 10))
  fi

  case "$os" in
    darwin)
      if [[ "$lowered" == *"darwin"* || "$lowered" == *"macos"* || "$lowered" == *"mac"* ]]; then
        score=$((score + 10))
      fi
      ;;
    linux)
      if [[ "$lowered" == *"linux"* ]]; then
        score=$((score + 10))
      fi
      ;;
  esac

  case "$arch" in
    x86_64)
      if [[ "$lowered" == *"x86_64"* || "$lowered" == *"amd64"* ]]; then
        score=$((score + 10))
      fi
      ;;
    arm64)
      if [[ "$lowered" == *"arm64"* || "$lowered" == *"aarch64"* ]]; then
        score=$((score + 10))
      fi
      ;;
  esac

  case "$lowered" in
    *.tar.gz | *.tgz | *.zip) score=$((score + 2)) ;;
  esac

  echo "$score"
}

list_release_assets() {
  local json="$1"

  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r '.assets[]? | [.name, .browser_download_url] | @tsv'
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json
import sys

raw = sys.stdin.read()
payload = json.loads(raw)
for asset in payload.get("assets", []):
    name = asset.get("name", "")
    url = asset.get("browser_download_url", "")
    if name and url:
        print(f"{name}\t{url}")
' <<<"$json"
    return 0
  fi

  die "need either jq or python3 to parse GitHub release metadata"
}

find_best_asset() {
  local os="$1"
  local arch="$2"
  local asset_lines="$3"
  local best_score=-1
  local best_name=""
  local best_url=""
  local line
  local name
  local url
  local score

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS=$'\t' read -r name url <<<"$line"
    [ -n "${name:-}" ] || continue
    [ -n "${url:-}" ] || continue

    score="$(score_asset_name "$name" "$os" "$arch")"

    if [ "$score" -gt "$best_score" ]; then
      best_score="$score"
      best_name="$name"
      best_url="$url"
    fi
  done <<<"$asset_lines"

  if [ "$best_score" -lt 30 ]; then
    return 1
  fi

  printf '%s\t%s\n' "$best_name" "$best_url"
}

download_release_metadata() {
  local api_url="$1"
  local -a curl_args

  curl_args=(-fsSL -H "Accept: application/vnd.github+json")

  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  curl "${curl_args[@]}" "$api_url"
}

locate_extracted_binary() {
  local root="$1"
  local candidate

  if [ -x "$root/symphony" ]; then
    printf '%s\n' "$root/symphony"
    return 0
  fi

  candidate="$(
    find "$root" -type f -name symphony -perm -u+x 2>/dev/null | head -n 1 || true
  )"

  if [ -n "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  candidate="$(
    find "$root" -type f -name symphony 2>/dev/null | head -n 1 || true
  )"

  if [ -n "$candidate" ]; then
    chmod +x "$candidate"
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

verify_installer() {
  local installer_path="$1"
  local output
  local status

  set +e
  output="$("$installer_path" --help 2>&1)"
  status=$?
  set -e

  if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
    die "installer at $installer_path failed '--help' probe with exit status $status"
  fi

  if [[ "$output" != *"Usage:"* ]] || [[ "$output" != *"symphony install --manifest <path>"* ]]; then
    die "installer at $installer_path failed usage contract probe"
  fi
}

ensure_install_dir_writable() {
  local install_dir="$1"

  if [ -e "$install_dir" ] && [ ! -d "$install_dir" ]; then
    die "install path exists but is not a directory: $install_dir"
  fi

  if [ ! -d "$install_dir" ]; then
    if ! mkdir -p "$install_dir"; then
      die "install directory is not writable or cannot be created: $install_dir"
    fi
  fi

  if [ ! -w "$install_dir" ]; then
    die "install directory is not writable: $install_dir"
  fi
}

install_binary() {
  local source_path="$1"
  local install_path="$2"

  if ! cp "$source_path" "$install_path"; then
    die "failed to copy symphony binary to $install_path (check directory and file permissions)"
  fi

  if ! chmod 0755 "$install_path"; then
    die "failed to set executable permissions on $install_path"
  fi
}

main() {
  local existing
  local release_repo
  local release_tag
  local install_dir
  local install_path
  local os
  local arch
  local api_url
  local release_json
  local asset_lines
  local selected_asset
  local asset_name
  local asset_url
  local tmp_dir
  local download_path
  local unpack_dir
  local extracted_binary
  local path_dir

  if existing="$(command -v symphony 2>/dev/null || true)"; [ -n "$existing" ]; then
    verify_installer "$existing"
    printf '%s\n' "$existing"
    exit 0
  fi

  require_command curl
  require_command tar

  release_repo="${SYMPHONY_RELEASE_REPO:-openai/symphony}"
  release_tag="${SYMPHONY_RELEASE_TAG:-latest}"
  install_dir="${SYMPHONY_INSTALL_DIR:-$HOME/.local/bin}"
  install_path="${install_dir}/symphony"
  os="$(normalize_os)"
  arch="$(normalize_arch)"

  if [ "$release_tag" = "latest" ]; then
    api_url="https://api.github.com/repos/${release_repo}/releases/latest"
  else
    api_url="https://api.github.com/repos/${release_repo}/releases/tags/${release_tag}"
  fi

  release_json="$(download_release_metadata "$api_url")"
  asset_lines="$(list_release_assets "$release_json")"

  if ! selected_asset="$(find_best_asset "$os" "$arch" "$asset_lines")"; then
    die "no matching release asset found in ${release_repo}@${release_tag} for ${os}/${arch} (v1 CI-published tuples: linux/x86_64, darwin/arm64)"
  fi

  IFS=$'\t' read -r asset_name asset_url <<<"$selected_asset"

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  download_path="$tmp_dir/$asset_name"
  unpack_dir="$tmp_dir/unpack"
  mkdir -p "$unpack_dir"

  log "downloading ${asset_name} from ${release_repo}@${release_tag}"
  curl -fsSL --retry 3 --output "$download_path" "$asset_url"

  case "$asset_name" in
    *.tar.gz | *.tgz)
      tar -xzf "$download_path" -C "$unpack_dir"
      ;;
    *.zip)
      require_command unzip
      unzip -q "$download_path" -d "$unpack_dir"
      ;;
    *)
      cp "$download_path" "$unpack_dir/symphony"
      chmod +x "$unpack_dir/symphony"
      ;;
  esac

  extracted_binary="$(locate_extracted_binary "$unpack_dir")" || {
    die "downloaded release asset did not contain a runnable 'symphony' binary"
  }

  ensure_install_dir_writable "$install_dir"
  install_binary "$extracted_binary" "$install_path"
  verify_installer "$install_path"

  path_dir=":${PATH}:"
  if [[ "$path_dir" != *":${install_dir}:"* ]]; then
    log "installed to ${install_path}"
    log "add ${install_dir} to PATH to call it directly as 'symphony'"
  fi

  printf '%s\n' "$install_path"
}

main "$@"
