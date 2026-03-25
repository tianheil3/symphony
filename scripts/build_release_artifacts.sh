#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ELIXIR_DIR="${REPO_ROOT}/elixir"
DIST_DIR="${REPO_ROOT}/dist/release"
CONCIERGE_DIR="${REPO_ROOT}/.codex/skills/symphony-concierge"

export PATH="/opt/homebrew/bin:${PATH}"

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

normalize_os() {
  local os
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"

  case "$os" in
    darwin) echo "darwin" ;;
    linux) echo "linux" ;;
    *) fail "unsupported OS: ${os}" ;;
  esac
}

normalize_arch() {
  local arch
  arch="$(uname -m | tr '[:upper:]' '[:lower:]')"

  case "$arch" in
    x86_64 | amd64) echo "x86_64" ;;
    arm64 | aarch64) echo "arm64" ;;
    *) fail "unsupported architecture: ${arch}" ;;
  esac
}

resolve_target_tuple() {
  local actual_os
  local actual_arch
  local target_os
  local target_arch

  actual_os="$(normalize_os)"
  actual_arch="$(normalize_arch)"
  target_os="${SYMPHONY_TARGET_OS:-}"
  target_arch="${SYMPHONY_TARGET_ARCH:-}"

  if [[ -n "${target_os}" && -z "${target_arch}" ]]; then
    fail "SYMPHONY_TARGET_OS is set but SYMPHONY_TARGET_ARCH is missing"
  fi

  if [[ -z "${target_os}" && -n "${target_arch}" ]]; then
    fail "SYMPHONY_TARGET_ARCH is set but SYMPHONY_TARGET_OS is missing"
  fi

  if [[ -z "${target_os}" ]]; then
    target_os="${actual_os}"
    target_arch="${actual_arch}"
  fi

  if [[ "${target_os}" != "${actual_os}" || "${target_arch}" != "${actual_arch}" ]]; then
    fail "requested target tuple ${target_os}/${target_arch} does not match runner tuple ${actual_os}/${actual_arch}"
  fi

  RESOLVED_TARGET_OS="${target_os}"
  RESOLVED_TARGET_ARCH="${target_arch}"
}

read_mix_version() {
  (
    cd "${ELIXIR_DIR}"
    MIX_ENV=prod mix run --no-start -e 'IO.write(Mix.Project.config()[:version])'
  )
}

detect_version() {
  local mix_version
  mix_version="$(read_mix_version)"

  if [[ -n "${SYMPHONY_VERSION:-}" ]]; then
    if [[ "${SYMPHONY_VERSION}" != "${mix_version}" ]]; then
      fail "SYMPHONY_VERSION (${SYMPHONY_VERSION}) does not match Mix version (${mix_version})"
    fi

    printf '%s\n' "${SYMPHONY_VERSION}"
    return 0
  fi

  printf '%s\n' "${mix_version}"
}

verify_installer_usage_contract() {
  local installer_path="$1"
  local output
  local status

  set +e
  output="$("$installer_path" --help 2>&1)"
  status=$?
  set -e

  if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
    fail "packaged installer help probe failed for ${installer_path} (exit: ${status})"
  fi

  if [[ "$output" != *"Usage:"* ]] || [[ "$output" != *"symphony install --manifest <path>"* ]]; then
    fail "packaged installer failed usage contract probe"
  fi
}

smoke_test_packaged_installer() {
  local installer_archive="$1"
  local staging_dir="$2"
  local extract_dir
  local extracted_binary

  extract_dir="${staging_dir}/smoke-installer"
  mkdir -p "${extract_dir}"

  tar -xzf "${installer_archive}" -C "${extract_dir}"

  if [[ -x "${extract_dir}/symphony" ]]; then
    extracted_binary="${extract_dir}/symphony"
  else
    fail "packaged installer archive did not contain executable 'symphony'"
  fi

  verify_installer_usage_contract "${extracted_binary}"
}

main() {
  local os
  local arch
  local version
  local installer_asset
  local concierge_asset
  local staging_dir
  local installer_staging

  RESOLVED_TARGET_OS=""
  RESOLVED_TARGET_ARCH=""

  [[ -d "${ELIXIR_DIR}" ]] || fail "missing elixir directory: ${ELIXIR_DIR}"
  [[ -d "${CONCIERGE_DIR}" ]] || fail "missing concierge bundle: ${CONCIERGE_DIR}"

  resolve_target_tuple
  os="${RESOLVED_TARGET_OS}"
  arch="${RESOLVED_TARGET_ARCH}"

  log "building symphony installer escript"
  (
    cd "${ELIXIR_DIR}"
    MIX_ENV=prod mix setup
    MIX_ENV=prod mix build
  )

  [[ -x "${ELIXIR_DIR}/bin/symphony" ]] || fail "expected built installer at elixir/bin/symphony"

  version="$(detect_version)"
  [[ -n "${version}" ]] || fail "failed to resolve version"

  installer_asset="symphony-${version}-${os}-${arch}.tar.gz"
  concierge_asset="symphony-concierge-${version}.tar.gz"

  rm -rf "${DIST_DIR}"
  mkdir -p "${DIST_DIR}"

  staging_dir="$(mktemp -d)"
  trap 'rm -rf "${staging_dir:-}"' EXIT

  installer_staging="${staging_dir}/installer"
  mkdir -p "${installer_staging}"
  cp "${ELIXIR_DIR}/bin/symphony" "${installer_staging}/symphony"
  chmod 0755 "${installer_staging}/symphony"

  tar -C "${installer_staging}" -czf "${DIST_DIR}/${installer_asset}" symphony
  tar -C "${REPO_ROOT}/.codex/skills" -czf "${DIST_DIR}/${concierge_asset}" symphony-concierge

  smoke_test_packaged_installer "${DIST_DIR}/${installer_asset}" "${staging_dir}"

  log "release artifacts:"
  log "- ${DIST_DIR}/${installer_asset}"
  log "- ${DIST_DIR}/${concierge_asset}"
}

main "$@"
