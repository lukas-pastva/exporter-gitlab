#!/bin/bash

# Function to URL-encode a string correctly handling UTF-8 characters
urlencode() {
    local string="$1"
    # Use jq to perform URL encoding
    printf '%s' "$string" | jq -s -R -r @uri
}

# Function to add metrics
metric_add() {
    local metric="$1"
    if ! grep -Fxq "$metric" /tmp/metrics.log; then
        echo "$metric" >> /tmp/metrics.log
        echo "$metric"
    else
        echo "Duplicate metric found, not adding: $metric" >&2
    fi
}

# Function to escape label values
escape_label_value() {
    local val="$1"
    val="${val//\\/\\\\}"  # Escape backslash
    val="${val//\"/\\\"}"  # Escape double quote
    val="${val//$'\n'/}"   # Remove newlines
    val="${val//$'\r'/}"   # Remove carriage returns
    echo -n "$val"
}

# Function to handle retries for API requests and log requests and failures
safe_curl() {
    local url="$1"
    local retries=3
    local wait_time=2
    for i in $(seq 1 $retries); do
        echo "$url" >> /tmp/curl_requests.log
        response=$(curl -k -s -f --header "PRIVATE-TOKEN: $PRIVATE_TOKEN" "$url")
        local exit_status=$?
        if [[ $exit_status -eq 0 ]]; then
            echo "$response"
            return 0
        fi
        echo "Attempt $i failed for URL: $url" >&2
        sleep $wait_time
    done
    echo "All $retries attempts failed for URL: $url" >&2
    echo "$url" >> /tmp/curl_failures.log
    return 1
}

# Function to get all members of a group
get_group_members() {
    local group_id="$1"
    local page=1
    local per_page=100
    while :; do
        local response=$(safe_curl "${GITLAB_API_URL}groups/${group_id}/members/all?per_page=$per_page&page=$page") || break
        local member_count=$(echo "$response" | jq 'length')
        if [[ $member_count -eq 0 ]]; then
            break
        fi
        echo "$response" | jq -c '.[]'
        ((page++))
    done
}

# Function to get all users (modified to get group members)
get_all_users() {
    get_group_members "$GROUP_ID"
}

# Function to get all groups (modified to return only the specified group)
get_all_groups() {
    echo "$GROUP_ID"
}

# Function to get all projects in a group with pagination
get_projects_in_group() {
    local group_id="$1"
    local page=1
    local per_page=100
    while :; do
        local response=$(safe_curl "${GITLAB_API_URL}groups/${group_id}/projects?per_page=${per_page}&page=${page}&with_shared=false") || break
        local project_count=$(echo "$response" | jq 'length')
        if [[ $project_count -eq 0 ]]; then
            break
        fi
        echo "$response" | jq -r '.[].id'
        ((page++))
    done
}

# Function to get all projects (modified to fetch projects only from the specified group)
get_all_projects() {
    declare -A seen_projects
    local project_id

    # Fetch projects from the specified group
    while IFS= read -r project_id; do
        if [[ -z "${seen_projects[$project_id]:-}" ]]; then
            echo "$project_id"
            seen_projects["$project_id"]=1
        fi
    done < <(get_projects_in_group "$GROUP_ID")
}

# Function to get all branches for a project
get_branches_for_project() {
    local project_id="$1"
    local page=1
    local per_page=100
    local all_branches=""
    while :; do
        local response=$(safe_curl "${GITLAB_API_URL}projects/$project_id/repository/branches?page=$page&per_page=$per_page") || break
        local branch_count=$(echo "$response" | jq 'length')
        if [[ $branch_count -eq 0 ]]; then
            break
        fi
        local branches=$(echo "$response" | jq -r '.[].name')
        all_branches+="$branches "
        ((page++))
    done
    echo "$all_branches"
}

# Function to get all commits for a project
get_commits_for_project() {
    local project_id="$1"
    local branches=$(get_branches_for_project "$project_id")
    local branch_array=($branches)
    local all_commits=""
    for branch in "${branch_array[@]}"; do
        # URL-encode the branch name
        local encoded_branch=$(urlencode "$branch")
        local page=1
        local per_page=100
        while :; do
            local url="${GITLAB_API_URL}projects/${project_id}/repository/commits?ref_name=${encoded_branch}&since=${SINCE_DATE}&until=${UNTIL_DATE}&page=${page}&per_page=${per_page}"
            local response=$(safe_curl "$url") || break
            local commit_count=$(echo "$response" | jq 'length')
            if [[ $commit_count -eq 0 ]]; then
                break
            fi
            local commits=$(echo "$response" | jq -r '.[] | @base64')
            all_commits+="$commits "
            ((page++))
        done
    done
    echo "$all_commits"
}

# Function to process commits for a project
process_commits_for_project() {
    local project_id="$1"
    local -n user_commit_count_ref="$2"
    local -n repo_commit_count_ref="$3"
    local -n total_commits_ref="$4"
    local commit_count=0
    echo -n "Processing commits for project: $project_id, "
    local commits_encoded=$(get_commits_for_project "$project_id")
    local commits_length=${#commits_encoded}
    echo -n "Number of commits fetched: $commits_length, "
    for commit_enc in $commits_encoded; do
        if [[ -z "$commit_enc" ]]; then
            continue
        fi

        local commit=$(echo "$commit_enc" | base64 --decode 2>/dev/null) || continue
        local email=$(echo "$commit" | jq -r '.author_email' | tr '[:upper:]' '[:lower:]' | xargs)

        if [[ -n "$email" && "$email" != "null" && "$email" =~ ^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$ ]]; then
            user_commit_count_ref["$email"]=$(( ${user_commit_count_ref["$email"]:-0} + 1 ))
            total_commits_ref=$(( total_commits_ref + 1 ))
            commit_count=$((commit_count + 1))
        fi
    done

    repo_commit_count_ref["$project_id"]=$commit_count
    echo "Commits processed: $commit_count"
}

# Function to collect GitLab user statistics and commits per repository
gitlab_user_statistics() {
    declare -A user_commit_count
    declare -A repo_commit_count
    declare -A project_names
    declare -A namespaces
    local total_commits=0
    local passive_users=0
    projects=()

    # All Users Count
    local all_users_count=0
    while IFS= read -r user_json; do
        all_users_count=$((all_users_count + 1))
    done < <(get_all_users)
    metric_add "gitlab_total_users{gitlab=\"${GITLAB_URL}\"} $all_users_count"

    # Populate the projects array
    while IFS= read -r project_id; do
        projects+=("$project_id")
    done < <(get_all_projects)

    local total_repos=${#projects[@]}
    metric_add "gitlab_total_repositories{gitlab=\"${GITLAB_URL}\"} $total_repos"

    # Process commits and add repository commit metrics for each project
    for project in "${projects[@]}"; do
        # Fetch project info
        local project_info=$(safe_curl "${GITLAB_API_URL}projects/$project") || continue
        local project_name=$(echo "$project_info" | jq -r '.name')
        local namespace=$(echo "$project_info" | jq -r '.namespace.name')
        project_names["$project"]="$project_name"
        namespaces["$project"]="$namespace"

        # Process commits for the current project
        process_commits_for_project "$project" user_commit_count repo_commit_count total_commits

        # Add repository commits metric for the current project
        local commit_count=${repo_commit_count["$project"]}
        local sanitized_project_name=$(escape_label_value "$project_name")
        local sanitized_namespace=$(escape_label_value "$namespace")
        metric_add "gitlab_repo_commits{gitlab=\"${GITLAB_URL}\",start_date=\"${START_DATE}\",project_id=\"$project\",project_name=\"$sanitized_project_name\",namespace=\"$sanitized_namespace\"} $commit_count"
    done

    # Add commit metrics per user
    for email in "${!user_commit_count[@]}"; do
        local commit_count=${user_commit_count[$email]}
        local sanitized_email=$(escape_label_value "$email")
        metric_add "gitlab_user_commits{gitlab=\"${GITLAB_URL}\",start_date=\"${START_DATE}\",user_email=\"$sanitized_email\"} $commit_count"
    done

    # Add total commits metric
    metric_add "gitlab_total_commits{gitlab=\"${GITLAB_URL}\",start_date=\"${START_DATE}\"} $total_commits"

    # Add active users metric
    local total_unique_users=${#user_commit_count[@]}
    metric_add "gitlab_active_users{gitlab=\"${GITLAB_URL}\",start_date=\"${START_DATE}\"} $total_unique_users"

    # Passive Users
    while IFS= read -r user_json; do
        local last_sign_in_at=$(echo "$user_json" | jq -r '.last_sign_in_at')
        if [[ "$last_sign_in_at" != "null" && -n "$last_sign_in_at" ]]; then
            local last_sign_in_epoch=$(date -d "$last_sign_in_at" +"%s" 2>/dev/null)

            # Check if last_sign_in_at is after SINCE_DATE_EPOCH
            if [[ "$last_sign_in_epoch" -ge "$SINCE_DATE_EPOCH" ]]; then
                local email=$(echo "$user_json" | jq -r '.email' | tr '[:upper:]' '[:lower:]' | xargs)

                # Ensure the user hasn't made any commits
                if [[ -z "${user_commit_count[$email]:-}" ]]; then
                    passive_users=$((passive_users + 1))
                fi
            fi
        fi
    done < <(get_all_users)

    metric_add "gitlab_passive_users{gitlab=\"${GITLAB_URL}\",start_date=\"${START_DATE}\"} $passive_users"
}

# Configuration Variables
GITLAB_URL=${GITLAB_URL:-"https://gitlab.com"}
GITLAB_API_URL="${GITLAB_URL}/api/v4/"
PRIVATE_TOKEN=${PRIVATE_TOKEN:-"your_access_token"}
GROUP_ID=${GROUP_ID:-"your_group_id"}  # Specify your group ID here
RUN_BEFORE_MINUTE=${RUN_BEFORE_MINUTE:-"5"}
RUN_AT_HOUR=${RUN_AT_HOUR:-"1"}
START_DATE=${START_DATE:-"30 days ago"}
SINCE_DATE_EPOCH=$(date -d "${START_DATE}" +"%s")
SINCE_DATE=$(date -d "${START_DATE}" +"%Y-%m-%dT00:00:00Z")
UNTIL_DATE=$(date +"%Y-%m-%dT23:59:59Z")
MICROTIME=$(date +%s%3N)
EPOCH=$(date +%s)
CURRENT_MIN=$((10#$(date +%M)))
CURRENT_HOUR=$(date +"%-H")
curl_request_count=0

# Run only once a day
if [[ $CURRENT_HOUR -eq ${RUN_AT_HOUR} ]] && [[ $CURRENT_MIN -lt ${RUN_BEFORE_MINUTE} ]]; then
    echo "" > /tmp/metrics.log
    echo "" > /tmp/curl_requests.log
    echo "" > /tmp/curl_failures.log
    metric_add "# scraping start $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    metric_add "gitlab_heart_beat{gitlab=\"${GITLAB_URL}\"} ${EPOCH}"

    echo "Running gitlab_user_statistics"
    gitlab_user_statistics

    # Final metrics
    curl_total_requests=$(grep -c '.' /tmp/curl_requests.log)
    metric_add "gitlab_curl_requests_total{gitlab=\"${GITLAB_URL}\"} $curl_total_requests"
    curl_failed_requests=$(grep -c '.' /tmp/curl_failures.log)
    metric_add "gitlab_curl_requests_failed{gitlab=\"${GITLAB_URL}\"} $curl_failed_requests"
    metric_add "gitlab_scrape_time{gitlab=\"${GITLAB_URL}\"} $(($(date +%s)-EPOCH))"
    metric_add "# scraping end $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
fi
