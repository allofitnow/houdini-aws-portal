#!/usr/bin/env bash
# aws/lib/fsm_labels.sh — FSM label transition function for GitLab workflow issues
# Purpose: Transitions fsm:: state labels on GitLab issues via the API.
# Preconditions: GITLAB_API_URL, GITLAB_TOKEN, GITLAB_PROJECT_ID must be set.

# ── Valid FSM states ──────────────────────────────────────────────────────────
readonly _FSM_VALID_STATES=(
  IDLE
  SCANNED
  REGION_SELECTED
  AMI_READY
  PORTAL_INFRA_READY
  UBL_READY
  FLEET_PLAN_READY
  FLEET_REQUESTED
  FLEET_FULFILLED
  WORKER_REGISTERED
  VALIDATED
  FAILED_CAPACITY
  FAILED_BOOT
  CANCELLED
  CLEANED_UP
)

# ── Guard: require environment ────────────────────────────────────────────────
_fsm_check_env() {
  local missing=0
  if [[ -z "${GITLAB_API_URL:-}" ]]; then
    echo "ERROR: GITLAB_API_URL is not set" >&2
    missing=1
  fi
  if [[ -z "${GITLAB_TOKEN:-}" ]]; then
    echo "ERROR: GITLAB_TOKEN is not set" >&2
    missing=1
  fi
  if [[ -z "${GITLAB_PROJECT_ID:-}" ]]; then
    echo "ERROR: GITLAB_PROJECT_ID is not set" >&2
    missing=1
  fi
  return "$missing"
}

# ── Guard: validate state name ───────────────────────────────────────────────
_fsm_validate_state() {
  local state="$1"
  local valid
  for valid in "${_FSM_VALID_STATES[@]}"; do
    if [[ "$state" == "$valid" ]]; then
      return 0
    fi
  done
  echo "ERROR: invalid FSM state '${state}'. Must be one of: ${_FSM_VALID_STATES[*]}" >&2
  return 1
}

# ── Main transition function ─────────────────────────────────────────────────
# Usage: fsm_transition ISSUE_IID NEW_STATE
fsm_transition() {
  local issue_iid="$1"
  local new_state="$2"

  _fsm_check_env || return 1
  _fsm_validate_state "$new_state" || return 1

  local project_id="${GITLAB_PROJECT_ID}"
  local api_url="${GITLAB_API_URL}"
  local token="${GITLAB_TOKEN}"

  # ── 1. GET current issue labels ────────────────────────────────────────────
  local get_url="${api_url}/projects/${project_id}/issues/${issue_iid}"
  local get_curl_cmd=(curl -s -f
    -H "PRIVATE-TOKEN: ${token}"
    "${get_url}")

  if [[ "${STATE_DRY_RUN:-0}" == "1" ]]; then
    echo "DRY-RUN: ${get_curl_cmd[*]}" >&2
  fi

  local response
  if [[ "${STATE_DRY_RUN:-0}" != "1" ]]; then
    response=$("${get_curl_cmd[@]}") || {
      echo "ERROR: failed to GET issue ${issue_iid}" >&2
      return 1
    }
  else
    # In dry-run, fabricate a minimal response so we can show the PUT too
    response='{"labels":["fsm::IDLE"]}'
  fi

  # ── 2. Find current fsm:: label ────────────────────────────────────────────
  local current_fsm_label
  current_fsm_label=$(echo "$response" | jq -r '.labels[] | select(startswith("fsm::"))')

  local fsm_count
  fsm_count=$(echo "$response" | jq '[.labels[] | select(startswith("fsm::"))] | length')

  if [[ "$fsm_count" -eq 0 ]]; then
    echo "ERROR: no fsm::* label found on issue ${issue_iid}" >&2
    return 1
  fi

  if [[ "$fsm_count" -gt 1 ]]; then
    echo "ERROR: multiple fsm::* labels found on issue ${issue_iid}: ${current_fsm_label}" >&2
    return 1
  fi

  local old_state="${current_fsm_label#fsm::}"

  # ── 3. Construct new labels ────────────────────────────────────────────────
  local new_fsm_label="fsm::${new_state}"
  local new_labels
  new_labels=$(echo "$response" \
    | jq -r --arg new "$new_fsm_label" '
        [.labels[] | select(startswith("fsm::") | not)] + [$new] | join(",")
      ')

  # ── 4. PUT updated labels ──────────────────────────────────────────────────
  local put_url="${api_url}/projects/${project_id}/issues/${issue_iid}"
  local put_body
  put_body=$(jq -n --arg labels "$new_labels" '{labels: $labels}')

  local put_curl_cmd=(curl -s -f
    -X PUT
    -H "PRIVATE-TOKEN: ${token}"
    -H "Content-Type: application/json"
    -d "$put_body"
    "${put_url}")

  if [[ "${STATE_DRY_RUN:-0}" == "1" ]]; then
    echo "DRY-RUN: ${put_curl_cmd[*]}" >&2
  else
    "${put_curl_cmd[@]}" > /dev/null || {
      echo "ERROR: failed to PUT labels on issue ${issue_iid}" >&2
      return 1
    }
  fi

  # ── 5. Print transition result ─────────────────────────────────────────────
  echo "TRANSITION ${old_state} → ${new_state}"
}
