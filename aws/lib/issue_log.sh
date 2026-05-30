#!/usr/bin/env bash
# aws/lib/issue_log.sh — Issue event log and inventory update functions
# Preconditions: GITLAB_API_URL, GITLAB_TOKEN, GITLAB_PROJECT_ID must be set
# Usage: source this file, then call issue_log / issue_update_inventory / issue_update_next_action

# ── Internal helpers ──────────────────────────────────────────────────────────

# Validate required GitLab environment variables.
# Prints error to stderr and returns 1 if any are missing.
_issue_log_check_env() {
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

# Build the project-scoped API URL prefix.
_issue_log_api_base() {
    echo "${GITLAB_API_URL}/projects/${GITLAB_PROJECT_ID}"
}

# Escape a string for safe embedding in a JSON value.
# Handles backslashes, double quotes, newlines, tabs, and carriage returns.
_issue_log_json_escape() {
    local input="$1"
    # Order matters: backslash first, then the rest
    input="${input//\\/\\\\}"
    input="${input//\"/\\\"}"
    input="${input//$'\n'/\\n}"
    input="${input//$'\t'/\\t}"
    input="${input//$'\r'/\\r}"
    printf '%s' "$input"
}

# Run curl or print the command in dry-run mode.
# Usage: _issue_log_curl METHOD URL [additional curl args...]
# Last argument must be the JSON body string prefixed with --data (handled specially).
_issue_log_curl() {
    local method="$1"; shift
    local url="$1"; shift

    # Separate data arguments from flag arguments so we can reconstruct the command
    local data_arg=""
    local flag_args=()
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--data" || "$1" == "-d" ]]; then
            shift
            data_arg="$1"
            shift
        else
            flag_args+=("$1")
            shift
        fi
    done

    local cmd=(curl -s -f -X "$method")
    cmd+=(-H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")
    cmd+=(-H "Content-Type: application/json")
    cmd+=("${flag_args[@]}")

    if [[ -n "$data_arg" ]]; then
        cmd+=(--data "$data_arg")
    fi

    cmd+=("$url")

    if [[ "${STATE_DRY_RUN:-0}" == "1" ]]; then
        # Print the curl command to stderr, do not execute
        printf '%s\n' "${cmd[*]}" >&2
        return 0
    fi

    "${cmd[@]}"
}

# GET an issue description. Prints raw JSON response to stdout.
_issue_log_get_issue() {
    local issue_iid="$1"
    local url
    url="$(_issue_log_api_base)/issues/${issue_iid}"
    _issue_log_curl GET "$url"
}

# PUT an updated issue description.
_issue_log_put_description() {
    local issue_iid="$1"
    local description="$2"
    local url
    url="$(_issue_log_api_base)/issues/${issue_iid}"
    local escaped_desc
    escaped_desc=$(_issue_log_json_escape "$description")
    local body="{\"description\":\"${escaped_desc}\"}"
    _issue_log_curl PUT "$url" --data "$body"
}

# ── Public functions ──────────────────────────────────────────────────────────

# issue_log ISSUE_IID MESSAGE
#   Append a timestamped event-log comment to issue ISSUE_IID.
#   Prints the new note ID to stdout on success.
issue_log() {
    local issue_iid="$1"
    local message="$2"

    _issue_log_check_env || return 1

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local full_message="[${timestamp}] ${message}"
    local escaped_message
    escaped_message=$(_issue_log_json_escape "$full_message")

    local url
    url="$(_issue_log_api_base)/issues/${issue_iid}/notes"
    local body="{\"body\":\"${escaped_message}\"}"

    local response
    response=$(_issue_log_curl POST "$url" --data "$body") || {
        echo "ERROR: Failed to post note to issue #${issue_iid}" >&2
        return 1
    }

    # Extract and print the note ID
    local note_id
    note_id=$(printf '%s' "$response" | jq -r '.id // empty')
    if [[ -z "$note_id" ]]; then
        echo "ERROR: No note ID in response" >&2
        return 1
    fi
    printf '%s\n' "$note_id"
}

# issue_update_inventory ISSUE_IID MARKDOWN_CONTENT
#   Replace the content between <!-- inventory:start --> and <!-- inventory:end -->
#   markers in the issue description. If markers don't exist, append them.
issue_update_inventory() {
    local issue_iid="$1"
    local markdown_content="$2"

    _issue_log_check_env || return 1

    # Fetch current issue description
    local response
    response=$(_issue_log_get_issue "$issue_iid") || {
        echo "ERROR: Failed to GET issue #${issue_iid}" >&2
        return 1
    }

    local description
    description=$(printf '%s' "$response" | jq -r '.description // ""')

    if [[ "$description" == "null" ]]; then
        description=""
    fi

    local new_desc
    if echo "$description" | grep -q '<!-- inventory:start -->' && \
       echo "$description" | grep -q '<!-- inventory:end -->'; then
        # Replace content between markers using sed
        # Use a temporary file to handle multi-line content safely
        local tmp_input
        tmp_input=$(mktemp)
        printf '%s\n' "$description" > "$tmp_input"

        local tmp_content
        tmp_content=$(mktemp)
        printf '%s' "$markdown_content" > "$tmp_content"

        # sed replacement: match from inventory:start to inventory:end and replace
        # Use a different approach with awk for multi-line safety
        local tmp_result
        tmp_result=$(mktemp)
        awk -v contentfile="$tmp_content" '
            /<!-- inventory:start -->/ {
                print
                while ((getline line < contentfile) > 0) print line
                # Skip everything until the end marker
                while ((getline) > 0) {
                    if (/<!-- inventory:end -->/) { print; nextfile }
                }
                next
            }
            { print }
        ' "$tmp_input" > "$tmp_result"

        new_desc=$(cat "$tmp_result")

        rm -f "$tmp_input" "$tmp_content" "$tmp_result"
    else
        # Markers don't exist — append them at the end
        new_desc="${description}

<!-- inventory:start -->
${markdown_content}
<!-- inventory:end -->"
    fi

    # PUT the updated description back
    _issue_log_put_description "$issue_iid" "$new_desc" > /dev/null || {
        echo "ERROR: Failed to PUT description for issue #${issue_iid}" >&2
        return 1
    }
}

# issue_update_next_action ISSUE_IID ACTION_TEXT
#   Replace the **Next action:** line in the issue description.
#   If the line doesn't exist, append it (before any <!-- mcp-state:start --> markers).
#   Does not exit 1 on missing line — creates it instead.
issue_update_next_action() {
    local issue_iid="$1"
    local action_text="$2"

    _issue_log_check_env || return 1

    # Fetch current issue description
    local response
    response=$(_issue_log_get_issue "$issue_iid") || {
        echo "ERROR: Failed to GET issue #${issue_iid}" >&2
        return 1
    }

    local description
    description=$(printf '%s' "$response" | jq -r '.description // ""')

    if [[ "$description" == "null" ]]; then
        description=""
    fi

    local new_desc
    if echo "$description" | grep -q '^\*\*Next action:\*\*'; then
        # Replace existing line using sed
        new_desc=$(printf '%s\n' "$description" | sed "s|^\*\*Next action:\*\*.*|**Next action:** ${action_text}|")
    else
        # No existing Next action line — insert before <!-- mcp-state:start --> if present,
        # otherwise append at the end.
        local new_line
        new_line="**Next action:** ${action_text}"

        if echo "$description" | grep -q '<!-- mcp-state:start -->'; then
            # Insert the Next action line before the mcp-state markers
            new_desc=$(printf '%s\n' "$description" | \
                sed "s|<!-- mcp-state:start -->|${new_line}\n\n<!-- mcp-state:start -->|")
        else
            # Append at the end
            new_desc="${description}

${new_line}"
        fi
    fi

    # PUT the updated description back
    _issue_log_put_description "$issue_iid" "$new_desc" > /dev/null || {
        echo "ERROR: Failed to PUT description for issue #${issue_iid}" >&2
        return 1
    }
}
