#!/usr/bin/env bash
#
# Connect to GKE and trigger Argo CD synchronization from:
# github.com/wilsonfv/istio-ambient-config
#
# Style Guide: Google Shell Style Guide
# https://google.github.io/styleguide/shellguide.html

set -o errexit
set -o nounset
set -o pipefail

# -----------------------------------------------------------------------------
# Global Constants and Defaults
# -----------------------------------------------------------------------------
readonly DEFAULT_CLUSTER_NAME="argocd-cluster"
readonly DEFAULT_REGION="europe-west1"
readonly DEFAULT_ZONE=""
readonly DEFAULT_ARGOCD_NAMESPACE="argocd"
readonly DEFAULT_ISTIO_NAMESPACE="istio-system"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Terminal colors
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_NC='\033[0m'

# Mutable runtime variables
PROJECT_ID="${PROJECT_ID:-}"
CLUSTER_NAME="${CLUSTER_NAME:-${DEFAULT_CLUSTER_NAME}}"
REGION="${REGION:-${DEFAULT_REGION}}"
ZONE="${ZONE:-${DEFAULT_ZONE}}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-${DEFAULT_ARGOCD_NAMESPACE}}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-${DEFAULT_ISTIO_NAMESPACE}}"
USE_APP_OF_APPS="${USE_APP_OF_APPS:-true}"

#######################################
# Print current timestamp in ISO format.
#######################################
timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

#######################################
# Log informational message.
#######################################
log_info() {
  echo -e "[$(timestamp)] ${COLOR_BLUE}[INFO]${COLOR_NC} $*"
}

#######################################
# Log success message.
#######################################
log_success() {
  echo -e "[$(timestamp)] ${COLOR_GREEN}[SUCCESS]${COLOR_NC} $*"
}

#######################################
# Log warning message.
#######################################
log_warn() {
  echo -e "[$(timestamp)] ${COLOR_YELLOW}[WARN]${COLOR_NC} $*" >&2
}

#######################################
# Log error message.
#######################################
log_error() {
  echo -e "[$(timestamp)] ${COLOR_RED}[ERROR]${COLOR_NC} $*" >&2
}

#######################################
# Retrieve active GCP project ID.
#######################################
get_gcloud_config_project() {
  gcloud config list --format='value(core.project)' 2>/dev/null || true
}

#######################################
# Display usage instructions.
#######################################
usage() {
  local active_project
  active_project="$(get_gcloud_config_project)"
  local display_project="${PROJECT_ID:-${active_project:-[not set]}}"

  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Syncs Istio Ambient Mode configurations from private GitHub repository to GKE via Argo CD.

Options:
  -p, --project PROJECT_ID     GCP Project ID (default: ${display_project})
  -c, --cluster CLUSTER_NAME   GKE Cluster name (default: ${CLUSTER_NAME})
  -r, --region REGION          GCP Region (default: ${REGION})
  -z, --zone ZONE              GCP Zone (optional, overrides region)
  -n, --namespace NAMESPACE    Argo CD namespace (default: ${ARGOCD_NAMESPACE})
  -h, --help                   Show this help message

Environment Variables:
  PROJECT_ID, CLUSTER_NAME, REGION, ZONE, ARGOCD_NAMESPACE
EOF
}

#######################################
# Parse command line flags.
#######################################
parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--project)
        PROJECT_ID="$2"
        shift 2
        ;;
      -c|--cluster)
        CLUSTER_NAME="$2"
        shift 2
        ;;
      -r|--region)
        REGION="$2"
        shift 2
        ;;
      -z|--zone)
        ZONE="$2"
        shift 2
        ;;
      -n|--namespace)
        ARGOCD_NAMESPACE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done
}

#######################################
# Resolve GCP Project ID.
#######################################
resolve_project_id() {
  if [[ -z "${PROJECT_ID}" ]]; then
    local config_project
    config_project="$(get_gcloud_config_project)"
    if [[ -n "${config_project}" ]]; then
      PROJECT_ID="${config_project}"
      log_info "Detected GCP project: ${PROJECT_ID}"
    else
      log_error "No GCP project found. Use -p or set PROJECT_ID."
      return 1
    fi
  fi
  gcloud config set project "${PROJECT_ID}" >/dev/null
}

#######################################
# Connect to target GKE cluster.
#######################################
connect_cluster() {
  local -a loc_flags=()
  if [[ -n "${ZONE}" ]]; then
    loc_flags=(--zone="${ZONE}")
  else
    loc_flags=(--region="${REGION}")
  fi

  log_info "Connecting to GKE cluster '${CLUSTER_NAME}' in project '${PROJECT_ID}'..."
  gcloud container clusters get-credentials "${CLUSTER_NAME}" "${loc_flags[@]}" --project "${PROJECT_ID}"
  log_success "Connected to cluster '${CLUSTER_NAME}'."
}

#######################################
# Configure Argo CD repository authentication.
#######################################
ensure_repo_auth() {
  log_info "Verifying Argo CD private repository credentials..."
  "${SCRIPT_DIR}/configure-argocd-repo.sh" -n "${ARGOCD_NAMESPACE}"
}

#######################################
# Deploy Argo CD applications.
#######################################
deploy_applications() {
  if [[ "${USE_APP_OF_APPS}" == "true" ]]; then
    log_info "Applying root App-of-Apps (${REPO_ROOT}/argocd/app-of-apps.yaml)..."
    kubectl apply -n "${ARGOCD_NAMESPACE}" -f "${REPO_ROOT}/argocd/app-of-apps.yaml"
  else
    log_info "Applying individual Argo CD applications from ${REPO_ROOT}/argocd/apps/..."
    local app_manifest
    for app_manifest in "${REPO_ROOT}/argocd/apps"/*.yaml; do
      log_info "Applying $(basename "${app_manifest}")..."
      kubectl apply -n "${ARGOCD_NAMESPACE}" -f "${app_manifest}"
    done
  fi
}

#######################################
# Wait for rollouts in istio-system.
#######################################
wait_for_rollouts() {
  log_info "Waiting for Argo CD to synchronize components..."

  log_info "Awaiting istiod control plane rollout..."
  kubectl rollout status deployment/istiod -n "${ISTIO_NAMESPACE}" --timeout=300s || true

  log_info "Awaiting Istio CNI Node DaemonSet rollout..."
  kubectl rollout status daemonset/istio-cni-node -n "${ISTIO_NAMESPACE}" --timeout=300s || true

  log_info "Awaiting Istio Ztunnel DaemonSet rollout..."
  kubectl rollout status daemonset/ztunnel -n "${ISTIO_NAMESPACE}" --timeout=300s || true

  log_success "Istio Ambient Mode components synchronization completed."
}

#######################################
# Print summary.
#######################################
print_summary() {
  echo ""
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_GREEN}     Istio Ambient Mode Sync Initiated from Private GitHub Repo     ${COLOR_NC}"
  echo -e "${COLOR_GREEN}=====================================================================${COLOR_NC}"
  echo -e "${COLOR_BOLD}Repository:${COLOR_NC}       https://github.com/wilsonfv/istio-ambient-config"
  echo -e "${COLOR_BOLD}GKE Cluster:${COLOR_NC}      ${CLUSTER_NAME}"
  echo -e "${COLOR_BOLD}Project ID:${COLOR_NC}       ${PROJECT_ID}"
  echo -e "${COLOR_BOLD}Argo CD Apps:${COLOR_NC}     kubectl get applications.argoproj.io -n ${ARGOCD_NAMESPACE}"
  echo ""
}

#######################################
# Main script entry point.
#######################################
main() {
  parse_flags "$@"
  resolve_project_id
  connect_cluster
  ensure_repo_auth
  deploy_applications
  wait_for_rollouts
  print_summary
}

main "$@"
