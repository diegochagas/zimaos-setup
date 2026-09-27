#!/usr/bin/env bash
#
# Self-managed projects: the repositories in projects.txt,
# cloned into PROJECTS_DIR (finances-tracker,
# homelab-monitor, ... — plain compose projects outside
# CasaOS app management), set up for push-to-deploy from
# the workstation, and their compose stacks started.
#
# Their gitignored secrets (.env.docker, monitor.env, ...)
# are not in git: restore them from the backup
# (Backups/Projects) before the stacks can start.
#

readonly PROJECTS_STEP_DIR="${BASH_SOURCE[0]%/*}"
readonly PROJECTS_FILE="$PROJECTS_STEP_DIR/projects.txt"
readonly PROJECTS_HOOK="$PROJECTS_STEP_DIR/post-receive"

# Number of changes made (or, in dry-run, planned) by the Projects step.
PROJECT_CHANGES=0

# Prints "<name>|<url>" for every project in projects.txt.
list_projects() {
    grep -vE '^\s*(#|$)' "$PROJECTS_FILE"
}

project_dir() {
    echo "$PROJECTS_DIR/$1"
}

# Prints the compose file of every cloned project that has one.
list_project_compose_files() {
    local name
    local url

    while IFS="|" read -r name url; do
        if [[ -f "$(project_dir "$name")/docker-compose.yml" ]]; then
            echo "$(project_dir "$name")/docker-compose.yml"
        fi
    done < <(list_projects)
}

# Clones a project unless its folder already exists.
clone_project() {
    local name="$1"
    local url="$2"
    local dir

    dir="$(project_dir "$name")"

    if [[ -d "$dir/.git" ]]; then
        return 0
    fi

    if [[ -e "$dir" ]]; then
        abort "$dir exists but is not a Git repository."
    fi

    run git clone "$url" "$dir"
    PROJECT_CHANGES=$((PROJECT_CHANGES + 1))
}

# Makes a clone accept pushes to its checked-out branch
# (updating the working tree) and installs the deploy hook.
configure_push_deploy() {
    local dir="$1"
    local hook="$dir/.git/hooks/post-receive"

    if [[ "$(git -C "$dir" config --get receive.denyCurrentBranch 2> /dev/null)" != updateInstead ]]; then
        run git -C "$dir" config receive.denyCurrentBranch updateInstead
        PROJECT_CHANGES=$((PROJECT_CHANGES + 1))
    fi

    if ! cmp -s "$PROJECTS_HOOK" "$hook"; then
        run install -m 0755 "$PROJECTS_HOOK" "$hook"
        PROJECT_CHANGES=$((PROJECT_CHANGES + 1))
    fi
}

configure_projects() {
    local name
    local url

    if [[ -z "${PROJECTS_DIR:-}" ]]; then
        skip_step "PROJECTS_DIR not set"
        return 0
    fi

    PROJECT_CHANGES=0

    if [[ ! -d "$PROJECTS_DIR" ]]; then
        run mkdir -p "$PROJECTS_DIR"
        PROJECT_CHANGES=$((PROJECT_CHANGES + 1))
    fi

    while IFS="|" read -r name url; do
        print_info "$name"
        clone_project "$name" "$url"

        # In dry-run a project that would be cloned doesn't exist yet.
        if [[ -d "$(project_dir "$name")/.git" ]]; then
            configure_push_deploy "$(project_dir "$name")"
        fi
    done < <(list_projects)

    if (( PROJECT_CHANGES == 0 )); then
        skip_step "Already configured"
    fi
}

# Starts the compose stack of every cloned project that has
# one and isn't running yet.
configure_project_stacks() {
    local compose_file
    local started=0
    local waiting=()

    if [[ -z "${PROJECTS_DIR:-}" ]]; then
        skip_step "PROJECTS_DIR not set"
        return 0
    fi

    skip_in_dry_run_without_sudo || return 0

    while read -r compose_file; do
        if [[ -n "$(sudo docker compose -f "$compose_file" ps -q 2> /dev/null)" ]]; then
            print_info "⏭️ Running: $(basename "$(dirname "$compose_file")")"
            continue
        fi

        # Fails on a missing env_file, i.e. secrets not restored yet.
        if ! sudo docker compose -f "$compose_file" config -q > /dev/null 2>&1; then
            waiting+=("$(basename "$(dirname "$compose_file")")")
            continue
        fi

        run sudo docker compose -f "$compose_file" up -d --build
        started=$((started + 1))
    done < <(list_project_compose_files)

    if (( ${#waiting[@]} > 0 )); then
        warn_step "Env files missing (restore from backup): ${waiting[*]}"
    elif (( started == 0 )); then
        skip_step "All running"
    fi
}

homelab_backup_timer_enabled() {
    systemctl is-enabled homelab-backup.timer > /dev/null 2>&1
}

# The server-side backup job belongs to homelab-backup,
# which installs it with its own script (needs its
# gitignored zimaos/config.sh, restored from the backup).
configure_homelab_backup_timer() {
    local backup_dir

    if [[ -z "${PROJECTS_DIR:-}" ]]; then
        skip_step "PROJECTS_DIR not set"
        return 0
    fi

    backup_dir="$(project_dir homelab-backup)"

    if homelab_backup_timer_enabled; then
        skip_step "Already enabled"
        return 0
    fi

    if [[ ! -f "$backup_dir/zimaos/config.sh" ]]; then
        warn_step "homelab-backup/zimaos/config.sh missing (restore from backup)"
        return 0
    fi

    run sudo "$backup_dir/zimaos/install-timer.sh"
}
