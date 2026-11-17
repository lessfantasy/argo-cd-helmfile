#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly REQUIRED_HELM_MAJOR="4"

#######################################
# logging
#######################################

log() {
  local level="$1"
  shift

  printf '[%s] [%s] %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$level" \
    "$*" >&2
}

log_info() {
  log INFO "$@"
}

log_warn() {
  log WARN "$@"
}

log_error() {
  log ERROR "$@"
}

#######################################
# cleanup
#######################################

cleanup() {
  if [[ -n "${TMP_ROOT:-}" && -d "${TMP_ROOT}" ]]; then
    rm -rf "${TMP_ROOT}"
  fi
}

trap cleanup EXIT

#######################################
# helpers
#######################################

require_binary() {
  local bin="$1"

  if ! command -v "$bin" >/dev/null 2>&1; then
    log_error "required binary not found: $bin"
    exit 1
  fi
}

truthy() {
  local val="${1:-}"

  case "${val,,}" in
    1|true|yes|on)
      return 0
      ;;
  esac

  return 1
}

variable_expansion() {
  local input="$1"

  if command -v envsubst >/dev/null 2>&1; then
    printf '%s' "$input" | envsubst
  else
    printf '%s' "$input"
  fi
}

expand_var_if_set() {
  local name="$1"

  if [[ -n "${!name:-}" ]]; then
    export "${name}=$(variable_expansion "${!name}")"
  fi
}

export_prefixed_envs() {
  local prefix="$1"

  while IFS='=' read -r -d '' name value; do
    if [[ "${name}" == "${prefix}"* ]]; then
      export "${name#${prefix}}=${value}"
    fi
  done < <(env -0)
}

append_env_options() {
  local value="$1"
  local -n out="$2"
  local item

  [[ -n "${value}" ]] || return 0

  # Newline-separated values are treated as already-tokenized arguments.
  # Space-separated values keep compatibility with the previous plugin behavior.
  if [[ "${value}" == *$'\n'* ]]; then
    while IFS= read -r item; do
      [[ -n "${item}" ]] || continue
      out+=("${item}")
    done <<< "${value}"
  else
    local old_ifs="${IFS}"
    local parsed=()
    IFS=' '
    read -r -a parsed <<< "${value}"
    IFS="${old_ifs}"
    out+=("${parsed[@]}")
  fi
}

cache_key_to_file() {
  local key="$1"
  local digest

  digest="$(printf '%s' "${key}" | sha256sum | awk '{print $1}')"
  printf '%s/%s' "${ARGOCD_HELMFILE_CACHE_ROOT}/repo-update" "${digest}"
}

cache_set_time() {
  local key="$1"
  local file

  file="$(cache_key_to_file "$key")"
  mkdir -p "$(dirname "${file}")"
  touch "${file}"
}

cache_get_time() {
  local key="$1"
  local file

  file="$(cache_key_to_file "$key")"

  if [[ -f "${file}" ]]; then
    stat -c %Y "${file}"
  fi
}

cache_is_valid() {
  local key="$1"
  local timeout="$2"

  [[ -n "${key}" ]] || return 1
  [[ -n "${timeout}" ]] || return 1
  [[ "${timeout}" =~ ^[0-9]+$ ]] || return 1
  [[ "${timeout}" -gt 0 ]] || return 1

  local cache_time
  cache_time="$(cache_get_time "${key}")"

  [[ -n "${cache_time}" ]] || return 1

  local current_time
  current_time="$(date +%s)"

  local diff=$((current_time - cache_time))

  [[ "${diff}" -le "${timeout}" ]]
}

#######################################
# validate phase
#######################################

if [[ $# -lt 1 ]]; then
  log_error "missing phase argument"
  exit 1
fi

PHASE="$1"

#######################################
# environment
#######################################

SCRIPT_NAME="$(basename "$0")"

export_prefixed_envs "ARGOCD_ENV_"
export_prefixed_envs "PARAM_"

export PATH="$(variable_expansion "${PATH}")"

expand_var_if_set HOME
expand_var_if_set HELMFILE_GLOBAL_OPTIONS
expand_var_if_set HELMFILE_TEMPLATE_OPTIONS
expand_var_if_set HELM_TEMPLATE_OPTIONS
expand_var_if_set HELMFILE_INIT_SCRIPT_FILE
expand_var_if_set ARGOCD_HELMFILE_CACHE_ROOT
expand_var_if_set HELM_CACHE_HOME
expand_var_if_set HELM_CONFIG_HOME
expand_var_if_set HELM_DATA_HOME

: "${HOME:=/home/argocd}"
: "${HELMFILE_ENV_FILE:=.argo-cd-helmfile-env}"

if [[ -f "${HELMFILE_ENV_FILE}" ]]; then
  log_info "loading env file: ${HELMFILE_ENV_FILE}"

  set -a
  # shellcheck disable=SC1090
  source "${HELMFILE_ENV_FILE}"
  set +a
fi

#######################################
# directories
#######################################

TMP_ROOT="$(mktemp -d "/tmp/${SCRIPT_NAME}.XXXXXX")"
export TMPDIR="${TMP_ROOT}"

: "${ARGOCD_HELMFILE_CACHE_ROOT:=${HOME}/.cache/argo-cd-helmfile}"

export HELM_CACHE_HOME="${HELM_CACHE_HOME:-${ARGOCD_HELMFILE_CACHE_ROOT}/helm/cache}"
export HELM_CONFIG_HOME="${HELM_CONFIG_HOME:-${ARGOCD_HELMFILE_CACHE_ROOT}/helm/config}"
export HELM_DATA_HOME="${HELM_DATA_HOME:-${ARGOCD_HELMFILE_CACHE_ROOT}/helm/data}"

mkdir -p \
  "${TMP_ROOT}" \
  "${HOME}" \
  "${ARGOCD_HELMFILE_CACHE_ROOT}/repo-update" \
  "${HELM_CACHE_HOME}" \
  "${HELM_CONFIG_HOME}" \
  "${HELM_DATA_HOME}"

#######################################
# binaries
#######################################

HELM_BINARY="${HELM_BINARY:-helm}"
HELMFILE_BINARY="${HELMFILE_BINARY:-helmfile}"

require_binary "${HELM_BINARY}"
require_binary "${HELMFILE_BINARY}"

HELM="$(command -v "${HELM_BINARY}")"
HELMFILE="$(command -v "${HELMFILE_BINARY}")"

#######################################
# versions
#######################################

HELM_VERSION_RAW="$(${HELM} version --template '{{ .Version }}')"
HELM_VERSION_RAW="${HELM_VERSION_RAW#v}"

IFS='.' read -r \
  HELM_MAJOR_VERSION \
  HELM_MINOR_VERSION \
  HELM_PATCH_VERSION \
  <<< "${HELM_VERSION_RAW%%-*}"

if [[ "${HELM_MAJOR_VERSION}" != "${REQUIRED_HELM_MAJOR}" ]]; then
  log_error "Unsupported Helm major version: ${HELM_MAJOR_VERSION}. This image supports Helm v${REQUIRED_HELM_MAJOR} only."
  exit 1
fi

log_info "Detected Helm v${HELM_MAJOR_VERSION}.${HELM_MINOR_VERSION}"
log_info "$(${HELM} version --short)"
log_info "$(${HELMFILE} --version)"

#######################################
# helmfile command
#######################################

HELMFILE_CMD=(
  "${HELMFILE}"
  --helm-binary "${HELM}"
  --no-color
  --allow-no-matching-release
)

if [[ -n "${ARGOCD_APP_NAMESPACE:-}" ]]; then
  if ! truthy "${HELMFILE_USE_CONTEXT_NAMESPACE:-false}"; then
    HELMFILE_CMD+=(--namespace "${ARGOCD_APP_NAMESPACE}")
  fi
fi

if [[ -n "${HELMFILE_GLOBAL_OPTIONS:-}" ]]; then
  append_env_options "${HELMFILE_GLOBAL_OPTIONS}" HELMFILE_CMD
fi

#######################################
# phases
#######################################

phase_init() {

  if truthy "${HELMFILE_CACHE_CLEANUP:-false}"; then
    "${HELMFILE_CMD[@]}" cache cleanup
  fi

  if [[ -n "${HELMFILE_INIT_SCRIPT_FILE:-}" ]]; then
    local init_script

    init_script="$(realpath "${HELMFILE_INIT_SCRIPT_FILE}")"

    log_info "running init script: ${init_script}"

    bash "${init_script}"
  fi

  local cache_key
  cache_key="${HELMFILE_REPO_CACHE_KEY:-plugin-init-repos-${ARGOCD_APP_NAME:-default}-${ARGOCD_APP_REVISION:-default}-${PWD}}"

  if ! cache_is_valid \
    "${cache_key}" \
    "${HELMFILE_REPO_CACHE_TIMEOUT:-0}"; then

    log_info "updating helm repositories"

    "${HELMFILE_CMD[@]}" repos

    cache_set_time "${cache_key}"

  else
    log_info "repository cache still valid"
  fi
}

phase_generate() {

  local helm_template_args=()

  if [[ -n "${KUBE_VERSION:-}" ]]; then
    helm_template_args+=("--kube-version=${KUBE_VERSION}")
  fi

  if [[ -n "${KUBE_API_VERSIONS:-}" ]]; then
    local old_ifs="${IFS}"
    local api_versions=()
    IFS=','
    read -r -a api_versions <<< "${KUBE_API_VERSIONS}"
    IFS="${old_ifs}"

    local version
    for version in "${api_versions[@]}"; do
      [[ -n "${version}" ]] || continue
      helm_template_args+=("--api-versions=${version}")
    done
  fi

  if [[ -n "${HELM_TEMPLATE_OPTIONS:-}" ]]; then
    append_env_options "${HELM_TEMPLATE_OPTIONS}" helm_template_args
  fi

  local helmfile_template_args=()

  if [[ -n "${HELMFILE_TEMPLATE_OPTIONS:-}" ]]; then
    append_env_options "${HELMFILE_TEMPLATE_OPTIONS}" helmfile_template_args
  fi

  local cmd=(
    "${HELMFILE_CMD[@]}"
    template
    --skip-deps
  )

  if [[ ${#helm_template_args[@]} -gt 0 ]]; then
    cmd+=(--args "$(printf '%s ' "${helm_template_args[@]}")")
  fi

  cmd+=("${helmfile_template_args[@]}")

  "${cmd[@]}"
}

phase_discover() {

  if [[ -n "${HELMFILE_DISCOVERY_RESPONSE:-}" ]]; then

    if truthy "${HELMFILE_DISCOVERY_RESPONSE}"; then
      echo "forced discovery response: enabled"
      exit 0
    else
      echo "forced discovery response: disabled"
      exit 1
    fi
  fi

  local files=(
    "helmfile.yaml"
    "helmfile.yaml.gotmpl"
  )

  local file
  for file in "${files[@]}"; do
    if [[ -f "${file}" ]]; then
      echo "valid helmfile content discovered"
      exit 0
    fi
  done

  if [[ -d "helmfile.d" ]]; then
    echo "valid helmfile content discovered"
    exit 0
  fi

  echo "no valid helmfile content discovered"
  exit 1
}

phase_parameters() {

  cat <<EOF
[
  {
    "name": "HELM_TEMPLATE_OPTIONS",
    "title": "HELM_TEMPLATE_OPTIONS",
    "tooltip": "helm template options"
  },
  {
    "name": "HELMFILE_TEMPLATE_OPTIONS",
    "title": "HELMFILE_TEMPLATE_OPTIONS",
    "tooltip": "helmfile template options"
  },
  {
    "name": "HELMFILE_GLOBAL_OPTIONS",
    "title": "HELMFILE_GLOBAL_OPTIONS",
    "tooltip": "helmfile global options"
  },
  {
    "name": "HELMFILE_INIT_SCRIPT_FILE",
    "title": "HELMFILE_INIT_SCRIPT_FILE",
    "tooltip": "init script path"
  },
  {
    "name": "HELMFILE_CACHE_CLEANUP",
    "title": "HELMFILE_CACHE_CLEANUP",
    "tooltip": "cleanup helmfile cache",
    "itemType": "boolean"
  },
  {
    "name": "HELMFILE_REPO_CACHE_TIMEOUT",
    "title": "HELMFILE_REPO_CACHE_TIMEOUT",
    "tooltip": "repository cache timeout in seconds"
  },
  {
    "name": "HELMFILE_USE_CONTEXT_NAMESPACE",
    "title": "HELMFILE_USE_CONTEXT_NAMESPACE",
    "tooltip": "use kube context namespace",
    "itemType": "boolean"
  }
]
EOF
}

#######################################
# dispatch
#######################################

log_info "starting phase: ${PHASE}"

case "${PHASE}" in

  init)
    phase_init
    ;;

  generate)
    phase_generate
    ;;

  discover)
    phase_discover
    ;;

  parameters)
    phase_parameters
    ;;

  *)
    log_error "invalid phase: ${PHASE}"
    exit 1
    ;;

esac

log_info "finished phase: ${PHASE}"
