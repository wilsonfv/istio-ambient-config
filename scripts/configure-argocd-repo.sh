#!/usr/bin/env bash
#
# Configure Argo CD repository credentials for the private GitHub repository:
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
readonly DEFAULT_REPO_URL="https://github.com/wilsonfv/istio-ambient-config.git"
readonly DEFAULT_REPO_USER="wilsonfv"
readonly DEFAULT_SECRET_NAME="repo-istio-ambient-config"
readonly DEFAULT_ARGOCD_NAMESPACE="argocd"

# Terminal colors
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_NC='\033[0m'

# Mutable runtime variables
REPO_URL="${REPO_URL:-${DEFAULT_REPO_URL}}"
REPO_USER="${REPO_USER:-${DEFAULT_REPO_USER}}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-${DEFAULT_ARGOCD_NAMESPACE}}"
SECRET_NAME="${SECRET_NAME:-${DEFAULT_SECRET_NAME}}"

#######################################
# Print current timestamp in ISO format.
#######################################
timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

#######################################
# Print an informational message.
#######################################
log_info() {
  echo -e "[$(timestamp)] ${COLOR_BLUE}[INFO]${COLOR_NC} $*"
}

#######################################
# Print a success message.
#######################################
log_success() {
  echo -e "[$(timestamp)] ${COLOR_GREEN}[SUCCESS]${COLOR_NC} $*"
}

#######################################
# Print a warning message.
#######################################
log_warn() {
  echo -e "[$(timestamp)] ${COLOR_YELLOW}[WARN]${COLOR_NC} $*" >&2
}

#######################################
# Print an error message.
#######################################
log_error() {
  echo -e "[$(timestamp)] ${COLOR_RED}[ERROR]${COLOR_NC} $*" >&2
}

#######################################
# Display usage instructions.
#######################################
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Configures Argo CD Kubernetes Secret with private GitHub credentials.

Options:
  -t, --token TOKEN        GitHub Personal Access Token (PAT)
  -u, --user USER          GitHub Username (default: ${REPO_USER})
  -n, --namespace NAMESPACE Argo CD Namespace (default: ${ARGOCD_NAMESPACE})
  -r, --repo REPO_URL      Repository URL (default: ${REPO_URL})
  -h, --help               Show this help message

Environment Variables:
  GITHUB_TOKEN, REPO_USER, ARGOCD_NAMESPACE, REPO_URL
EOF
}

#######################################
# Parse command line flags.
#######################################
parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--token)
        GITHUB_TOKEN="$2"
        shift 2
        ;;
      -u|--user)
        REPO_USER="$2"
        shift 2
        ;;
      -n|--namespace)
        ARGOCD_NAMESPACE="$2"
        shift 2
        ;;
      -r|--repo)
        REPO_URL="$2"
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
# Discover GitHub PAT if not provided.
#######################################
discover_token() {
  if [[ -n "${GITHUB_TOKEN}" ]]; then
    return 0
  fi

  # Attempt detection from git remote URL in parent/current repository
  local remote_url
  remote_url="$(git remote get-url origin 2>/dev/null || true)"
  if [[ "${remote_url}" =~ oauth2:([^@]+)@ ]]; then
    GITHUB_TOKEN="${BASH_REMATCH[1]}"
    log_info "Discovered GitHub token from local git remote configuration."
    return 0
  fi

  if [[ -z "${GITHUB_TOKEN}" ]]; then
    log_error "GitHub Personal Access Token is required to access private repository '${REPO_URL}'."
    log_error "Provide it via -t/--token or GITHUB_TOKEN environment variable."
    return 1
  fi
}

#######################################
# Verify Kubernetes cluster connection.
#######################################
check_cluster() {
  log_info "Verifying connection to Kubernetes cluster..."
  if ! kubectl cluster-info &>/dev/null; then
    log_error "Cannot connect to Kubernetes cluster. Ensure your kubeconfig is active."
    return 1
  fi
}

#######################################
# Create or update Argo CD repository secret.
#######################################
create_argocd_secret() {
  log_info "Configuring Argo CD repository Secret '${SECRET_NAME}' in namespace '${ARGOCD_NAMESPACE}'..."

  # Ensure argocd namespace exists
  kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  # Create or replace secret
  kubectl create secret generic "${SECRET_NAME}" \
    --namespace="${ARGOCD_NAMESPACE}" \
    --from-literal=type="git" \
    --from-literal=url="${REPO_URL}" \
    --from-literal=username="${REPO_USER}" \
    --from-literal=password="${GITHUB_TOKEN}" \
    --dry-run=client -o yaml | \
    kubectl label --local -f - "argocd.argoproj.io/secret-type=repository" -o yaml | \
    kubectl apply -f -

  log_success "Argo CD repository secret '${SECRET_NAME}' configured successfully for ${REPO_URL}."
}

#######################################
# Main script entry point.
#######################################
main() {
  parse_flags "$@"
  discover_token
  check_cluster
  create_argocd_secret
}

main "$@"
