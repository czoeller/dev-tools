#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
  pwd
)"

ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

log_error() {
  printf 'Error: %s\n' "$*" >&2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    log_error "Required command not found: $1"
    exit 1
  }
}

require_variable() {
  local variable_name="$1"

  if [[ -z "${!variable_name:-}" ]]; then
    log_error "Required variable is missing in ${ENV_FILE}: ${variable_name}"
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# Load .env
# -----------------------------------------------------------------------------

if [[ ! -f "$ENV_FILE" ]]; then
  log_error "Environment file not found: ${ENV_FILE}"
  log_error "Copy .env.sample to .env and configure it."
  exit 1
fi

# This executes the .env file as shell syntax.
# Only use a trusted, locally maintained .env file.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

require_variable "GITHUB_OWNER"
require_variable "GPG_PRIVATE_KEY_FILE"
require_variable "SIGNING_KEY_ID"
require_variable "SIGNING_PASSWORD"
require_variable "REPOSITORIES"

require_command "gh"

# Resolve relative key paths relative to the script directory.
if [[ "$GPG_PRIVATE_KEY_FILE" != /* ]]; then
  GPG_PRIVATE_KEY_FILE="${SCRIPT_DIR}/${GPG_PRIVATE_KEY_FILE}"
fi

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------

gh auth status >/dev/null 2>&1 || {
  log_error "GitHub CLI is not authenticated. Run: gh auth login"
  exit 1
}

if [[ ! -f "$GPG_PRIVATE_KEY_FILE" ]]; then
  log_error "GPG private key not found: ${GPG_PRIVATE_KEY_FILE}"
  exit 1
fi

mapfile -t repository_names < <(
  printf '%s\n' "$REPOSITORIES" |
    sed \
      -e 's/#.*$//' \
      -e 's/^[[:space:]]*//' \
      -e 's/[[:space:]]*$//' |
    grep -v '^$'
)

if [[ ${#repository_names[@]} -eq 0 ]]; then
  log_error "Repository whitelist is empty."
  exit 1
fi

# -----------------------------------------------------------------------------
# Update secrets
# -----------------------------------------------------------------------------

failed_repositories=()

for repository_name in "${repository_names[@]}"; do
  if [[ "$repository_name" == */* ]]; then
    repository="$repository_name"
  else
    repository="${GITHUB_OWNER}/${repository_name}"
  fi

  printf '\nUpdating secrets for %s...\n' "$repository"

  if ! gh repo view "$repository" >/dev/null 2>&1; then
    log_error "Repository does not exist or is not accessible: ${repository}"
    failed_repositories+=("$repository")
    continue
  fi

  if ! gh secret set GPG_KEY_CONTENTS \
    --repo "$repository" \
    < "$GPG_PRIVATE_KEY_FILE"
  then
    log_error "Failed to set GPG_KEY_CONTENTS for ${repository}"
    failed_repositories+=("$repository")
    continue
  fi

  if ! printf '%s' "$SIGNING_KEY_ID" |
    gh secret set SIGNING_KEY_ID --repo "$repository"
  then
    log_error "Failed to set SIGNING_KEY_ID for ${repository}"
    failed_repositories+=("$repository")
    continue
  fi

  if ! printf '%s' "$SIGNING_PASSWORD" |
    gh secret set SIGNING_PASSWORD --repo "$repository"
  then
    log_error "Failed to set SIGNING_PASSWORD for ${repository}"
    failed_repositories+=("$repository")
    continue
  fi

  printf 'Successfully updated %s\n' "$repository"
done

unset SIGNING_PASSWORD

# -----------------------------------------------------------------------------
# Result
# -----------------------------------------------------------------------------

printf '\n'

if [[ ${#failed_repositories[@]} -gt 0 ]]; then
  log_error "Failed repositories:"

  printf '  - %s\n' "${failed_repositories[@]}" >&2
  exit 1
fi

printf 'All whitelisted repositories were updated successfully.\n'