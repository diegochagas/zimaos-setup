#!/usr/bin/env bash
#
# Sudoers rules for the user running the setup, in
# /etc/sudoers.d/<user>-<name>:
#
# - rsync-backup: passwordless `sudo rsync`, so homelab-backup
#   on the workstation can pull root-only AppData folders
#   (rsync --rsync-path="sudo /usr/bin/rsync").
# - deploy: passwordless `docker compose up -d --build` for
#   exactly the compose files of the cloned projects, run by
#   the push-to-deploy hook (see steps/projects).
#
# Every file is checked with visudo before it is installed.
#

SUDOERS_USER="$(id -un)"
readonly SUDOERS_USER

sudoers_rsync_backup_rule() {
    echo "$SUDOERS_USER ALL=(root) NOPASSWD: /usr/bin/rsync"
}

sudoers_deploy_rule() {
    local compose_file

    while read -r compose_file; do
        echo "$SUDOERS_USER ALL=(root) NOPASSWD: /usr/bin/docker compose -f $compose_file up -d --build"
    done < <(list_project_compose_files)
}

# Installs a sudoers file unless it already has this content.
#
# Arguments:
#   $1 - Rule name (file /etc/sudoers.d/<user>-<name>)
#   stdin - File content
install_sudoers_file() {
    local target="/etc/sudoers.d/$SUDOERS_USER-$1"
    local candidate

    candidate="$(make_work_dir sudoers)/$1"
    cat > "$candidate"

    if [[ ! -s "$candidate" ]]; then
        print_info "⏭️ $1: no rules"
        return 1
    fi

    if sudo cmp -s "$candidate" "$target"; then
        print_info "⏭️ $1: up to date"
        return 1
    fi

    sudo visudo -cqf "$candidate" || abort "Invalid sudoers rules for $1"

    run sudo install -m 0440 -o root -g root "$candidate" "$target"
}

configure_sudoers() {
    local changed=0

    skip_in_dry_run_without_sudo || return 0

    sudoers_rsync_backup_rule | install_sudoers_file rsync-backup && changed=1

    if [[ -n "${PROJECTS_DIR:-}" ]]; then
        sudoers_deploy_rule | install_sudoers_file deploy && changed=1
    fi

    if (( changed == 0 )); then
        skip_step "Already configured"
    fi
}
