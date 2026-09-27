#!/usr/bin/env bash
#
# Extra CasaOS app stores from config.sh (EXTRA_APP_STORES),
# registered before the apps are installed. The official
# ZimaOS store is already registered on a fresh install.
#

if [[ -z "${EXTRA_APP_STORES+x}" ]]; then
    EXTRA_APP_STORES=()
fi

configure_app_stores() {
    local registered_stores
    local store_url
    local registered_count=0

    if (( ${#EXTRA_APP_STORES[@]} == 0 )); then
        skip_step "None configured"
        return 0
    fi

    registered_stores="$(casaos-cli app-management list app-stores 2> /dev/null || true)"

    for store_url in "${EXTRA_APP_STORES[@]}"; do
        if grep -qF "$store_url" <<< "$registered_stores"; then
            print_info "⏭️ Already registered: $store_url"
            continue
        fi

        run casaos-cli app-management register app-store "$store_url"
        registered_count=$((registered_count + 1))
    done

    if (( registered_count == 0 )); then
        skip_step "Already registered"
    fi
}
