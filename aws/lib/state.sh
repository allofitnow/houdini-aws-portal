#!/usr/bin/env bash
# aws/lib/state.sh — GitLab issue state block read/write library
# Reads and writes a JSON state block inside GitLab issue descriptions.
# Source this file; defines functions only, no code on load.

# ── Internal helpers ──────────────────────────────────────────────────────────

# Print an error message to stderr and exit 1.
_state_die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Verify that required environment variables are set.
_state_check_env() {
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
    if (( missing )); then
        exit 1
    fi
}

# Build the GitLab API URL for a given issue IID.
_state_issue_url() {
    local issue_iid="$1"
    echo "${GITLAB_API_URL}/projects/${GITLAB_PROJECT_ID}/issues/${issue_iid}"
}

# Execute a curl command (or dry-run print it).
# Usage: _state_curl ARGS...
_state_curl() {
    if [[ "${STATE_DRY_RUN:-0}" == "1" ]]; then
        echo "curl $*" >&2
        return 0
    fi
    curl -s -f "$@"
}

# GET the issue description. Prints raw description to stdout.
_state_get_description() {
    local issue_iid="$1"
    local url
    url="$(_state_issue_url "$issue_iid")"

    local response
    response=$(_state_curl \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "$url") || _state_die "Failed to GET issue ${issue_iid}"

    # Extract .description field; jq -r strips surrounding quotes and unescapes.
    echo "$response" | jq -r '.description // empty'
}

# PUT the updated description back to GitLab.
_state_put_description() {
    local issue_iid="$1"
    local description="$2"
    local url
    url="$(_state_issue_url "$issue_iid")"

    # Build JSON payload with jq to guarantee proper escaping.
    local payload
    payload=$(jq -n --arg desc "$description" '{description: $desc}')

    _state_curl \
        --request PUT \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        --header "Content-Type: application/json" \
        --data "$payload" \
        "$url" >/dev/null || _state_die "Failed to PUT issue ${issue_iid}"
}

# Extract the JSON content between state markers from a description.
# Prints the JSON to stdout. Returns 1 if markers not found.
_state_extract_block() {
    local description="$1"
    local json
    # Use sed to grab everything between the markers (exclusive of markers).
    json=$(echo "$description" | sed -n '/<!-- mcp-state:start -->/,/<!-- mcp-state:end -->/{
        /<!-- mcp-state:start -->/d
        /<!-- mcp-state:end -->/d
        p
    }')

    if [[ -z "$json" ]]; then
        return 1
    fi
    echo "$json"
}

# Replace the content between state markers in a description.
# Prints the new description to stdout.
_state_replace_block() {
    local description="$1"
    local new_json="$2"

    # We use a temp file because sed patterns contain special chars and
    # multiline replacement is tricky in pure bash.
    local tmp
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' RETURN

    # Write the description to a temp file, then use sed to replace between markers.
    echo "$description" > "$tmp"

    # Build replacement text safely: start marker + new JSON + end marker
    # Using awk for reliable multiline replacement.
    local start_marker='<!-- mcp-state:start -->'
    local end_marker='<!-- mcp-state:end -->'

    awk -v start="$start_marker" -v end="$end_marker" -v newjson="$new_json" '
        BEGIN { in_block = 0; found = 0 }
        $0 == start { in_block = 1; found = 1; print; print newjson; next }
        $0 == end   { in_block = 0; print; next }
        in_block    { next }
        { print }
    ' "$tmp"
}

# ── Public API ────────────────────────────────────────────────────────────────

# state_init ISSUE_IID INITIAL_STATE
# Ensure the state block exists in the issue description.
# If it already exists, do nothing (idempotent).
# If not, append a new state block with the given initial FSM state.
state_init() {
    local issue_iid="$1"
    local initial_state="$2"

    _state_check_env

    if [[ -z "$issue_iid" ]]; then
        _state_die "state_init: ISSUE_IID is required"
    fi
    if [[ -z "$initial_state" ]]; then
        _state_die "state_init: INITIAL_STATE is required"
    fi

    local description
    description=$(_state_get_description "$issue_iid")

    # Check if state block already exists.
    if echo "$description" | grep -q '<!-- mcp-state:start -->'; then
        echo "State block already exists"
        return 0
    fi

    # Build the state block.
    local state_json
    state_json=$(jq -n \
        --arg fsm "$initial_state" \
        --arg pid "$GITLAB_PROJECT_ID" \
        --arg iid "$issue_iid" \
        '{fsm_state: $fsm, workflow_id: "", gitlab: {project_id: $pid, issue_iid: $iid}}')

    local new_block
    new_block="<!-- mcp-state:start -->
${state_json}
<!-- mcp-state:end -->"

    # Append the state block to the description.
    local new_description
    if [[ -z "$description" ]]; then
        new_description="$new_block"
    else
        new_description="${description}

${new_block}"
    fi

    _state_put_description "$issue_iid" "$new_description"
}

# state_read ISSUE_IID
# Extract and print the JSON between the state markers.
state_read() {
    local issue_iid="$1"

    _state_check_env

    if [[ -z "$issue_iid" ]]; then
        _state_die "state_read: ISSUE_IID is required"
    fi

    local description
    description=$(_state_get_description "$issue_iid")

    local json
    json=$(_state_extract_block "$description") || _state_die "state_read: state markers not found in issue ${issue_iid}"

    echo "$json"
}

# state_write ISSUE_IID JSON_STRING
# Replace only the JSON content between the state markers.
# Does not touch anything outside the markers.
state_write() {
    local issue_iid="$1"
    local json_string="$2"

    _state_check_env

    if [[ -z "$issue_iid" ]]; then
        _state_die "state_write: ISSUE_IID is required"
    fi
    if [[ -z "$json_string" ]]; then
        _state_die "state_write: JSON_STRING is required"
    fi

    local description
    description=$(_state_get_description "$issue_iid")

    # Verify markers exist.
    if ! echo "$description" | grep -q '<!-- mcp-state:start -->'; then
        _state_die "state_write: state markers not found in issue ${issue_iid}"
    fi

    local new_description
    new_description=$(_state_replace_block "$description" "$json_string")

    _state_put_description "$issue_iid" "$new_description"
}

# state_get_field ISSUE_IID FIELD_NAME
# Calls state_read internally and prints the value of FIELD_NAME using jq.
state_get_field() {
    local issue_iid="$1"
    local field_name="$2"

    if [[ -z "$issue_iid" ]]; then
        _state_die "state_get_field: ISSUE_IID is required"
    fi
    if [[ -z "$field_name" ]]; then
        _state_die "state_get_field: FIELD_NAME is required"
    fi

    local json
    json=$(state_read "$issue_iid")

    local value
    value=$(echo "$json" | jq -r --arg f "$field_name" '.[$f] // empty') || _state_die "state_get_field: field '${field_name}' not found or jq parse error"

    if [[ -z "$value" ]]; then
        _state_die "state_get_field: field '${field_name}' not found"
    fi

    echo "$value"
}
