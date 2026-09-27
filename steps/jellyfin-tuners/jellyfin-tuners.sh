#!/usr/bin/env bash
#
# Jellyfin Live TV: adds the M3U tuners listed in tuners.txt
# to Jellyfin's livetv.xml, skipping the ones already present
# (matched by URL, so tuners added from the web UI are left
# alone). Jellyfin is stopped while the file is edited and
# started again afterwards, only when something changed.
#
# livetv.xml belongs to the container user and docker needs
# root, so the edit and the restart run with sudo.
#

readonly JELLYFIN_TUNERS_FILE="${BASH_SOURCE[0]%/*}/tuners.txt"
readonly JELLYFIN_CONTAINER="jellyfin"

jellyfin_livetv_xml() {
    echo "$APPDATA_ROOT/jellyfin/config/livetv.xml"
}

# Escapes a value for use as XML text.
xml_escape() {
    local value="$1"

    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    printf '%s' "$value"
}

# Prints one <TunerHostInfo> element with Jellyfin's
# defaults for an M3U tuner (same values the web UI saves).
#
# Arguments:
#   $1 - Friendly name
#   $2 - Playlist URL
jellyfin_tuner_xml() {
    local name
    local url
    local id

    name="$(xml_escape "$1")"
    url="$(xml_escape "$2")"
    id="$(tr -d '-' < /proc/sys/kernel/random/uuid)"

    cat << EOF
    <TunerHostInfo>
      <Id>$id</Id>
      <Url>$url</Url>
      <Type>m3u</Type>
      <FriendlyName>$name</FriendlyName>
      <ImportFavoritesOnly>false</ImportFavoritesOnly>
      <AllowHWTranscoding>true</AllowHWTranscoding>
      <AllowFmp4TranscodingContainer>false</AllowFmp4TranscodingContainer>
      <AllowStreamSharing>true</AllowStreamSharing>
      <FallbackMaxStreamingBitrate>30000000</FallbackMaxStreamingBitrate>
      <EnableStreamLooping>false</EnableStreamLooping>
      <TunerCount>0</TunerCount>
      <IgnoreDts>true</IgnoreDts>
      <ReadAtNativeFramerate>false</ReadAtNativeFramerate>
    </TunerHostInfo>
EOF
}

# Prints livetv.xml with the given tuner elements inserted
# right before </TunerHosts>. An empty list is saved by
# Jellyfin as <TunerHosts />, which is first expanded into
# an open/close pair.
#
# Arguments:
#   $1 - livetv.xml path
#   $2 - Tuner elements to insert
insert_jellyfin_tuners() {
    NEW_TUNERS="$2" awk '
        /<TunerHosts \/>/ {
            sub(/<TunerHosts \/>/, "<TunerHosts>\n  </TunerHosts>")
        }
        {
            n = split($0, lines, "\n")
            for (i = 1; i <= n; i++) {
                if (lines[i] ~ /<\/TunerHosts>/) printf "%s", ENVIRON["NEW_TUNERS"]
                print lines[i]
            }
        }
    ' "$1"
}

# Prints livetv.xml with the Url of the tuner named $2
# replaced by $3 (both XML-escaped).
#
# Arguments:
#   $1 - livetv.xml path
#   $2 - Friendly name
#   $3 - New playlist URL
update_jellyfin_tuner_url() {
    TUNER_NAME="$2" TUNER_URL="$3" awk '
        /<TunerHostInfo>/ { in_block = 1; block = "" }
        in_block {
            block = block $0 "\n"
            if ($0 ~ /<\/TunerHostInfo>/) {
                in_block = 0
                if (index(block, "<FriendlyName>" ENVIRON["TUNER_NAME"] "</FriendlyName>")) {
                    sub(/<Url>[^<]*<\/Url>/, "<Url>" ENVIRON["TUNER_URL"] "</Url>", block)
                }
                printf "%s", block
            }
            next
        }
        { print }
    ' "$1"
}

# Calls the Jellyfin API with JELLYFIN_URL/JELLYFIN_API_KEY
# from config.sh.
jellyfin_api() {
    local path="$1"
    shift

    curl -fsS --max-time 30 \
        -H "Authorization: MediaBrowser Token=\"$JELLYFIN_API_KEY\"" \
        "$@" "$JELLYFIN_URL$path"
}

# Starts Jellyfin's "Refresh Guide" task, which reloads the
# tuners' channel lists, once Jellyfin answers again after the
# restart. Needs JELLYFIN_URL and JELLYFIN_API_KEY; without
# them the task runs on its own schedule.
refresh_jellyfin_guide() {
    local task_id

    if [[ -z "${JELLYFIN_URL:-}" || -z "${JELLYFIN_API_KEY:-}" ]]; then
        print_info "Channels update when Jellyfin's \"Refresh Guide\" task runs"
        print_info "(Dashboard > Scheduled Tasks)."
        return 0
    fi

    if is_dry_run; then
        print_info "➜ Start Jellyfin's Refresh Guide task"
        return 0
    fi

    for _ in {1..30}; do
        task_id="$(jellyfin_api /ScheduledTasks 2> /dev/null |
            jq -r 'first(.[] | select(.Key == "RefreshGuide") | .Id) // empty' || true)"
        [[ -n "$task_id" ]] && break
        sleep 5
    done

    if [[ -z "$task_id" ]]; then
        warn_step "Jellyfin didn't come back — run Refresh Guide by hand"
        return 0
    fi

    run jellyfin_api "/ScheduledTasks/Running/$task_id" -X POST
    print_info "Refresh Guide started — channels update in a minute or two."
}

configure_jellyfin_tuners() {
    local livetv_xml
    local name
    local url
    local escaped_name
    local escaped_url
    local new_tuners=""
    local changes=0
    local work_dir
    local updated_xml

    livetv_xml="$(jellyfin_livetv_xml)"

    # Jellyfin writes livetv.xml on its first start, so a fresh
    # install has to be opened once (startup wizard) first.
    if [[ ! -f "$livetv_xml" ]]; then
        skip_step "Jellyfin not initialized yet — finish its startup wizard and run again"
        return 0
    fi

    work_dir="$(make_work_dir jellyfin)"
    updated_xml="$work_dir/livetv.xml"
    cp "$livetv_xml" "$updated_xml"

    while IFS="|" read -r name url; do
        [[ -z "$name" || "$name" == \#* ]] && continue

        escaped_name="$(xml_escape "$name")"
        escaped_url="$(xml_escape "$url")"

        if grep -qF "<Url>$escaped_url</Url>" "$updated_xml"; then
            print_info "⏭️ Already present: $name"
            continue
        fi

        # A tuner is matched by name, so changing its URL in
        # tuners.txt updates it instead of adding a second one.
        if grep -qF "<FriendlyName>$escaped_name</FriendlyName>" "$updated_xml"; then
            print_info "➜ Updating tuner URL: $name ($url)"
            update_jellyfin_tuner_url "$updated_xml" "$escaped_name" "$escaped_url" > "$work_dir/next.xml"
            mv "$work_dir/next.xml" "$updated_xml"
        else
            print_info "➜ Adding tuner: $name ($url)"
            new_tuners+="$(jellyfin_tuner_xml "$name" "$url")"$'\n'
        fi

        changes=$((changes + 1))
    done < "$JELLYFIN_TUNERS_FILE"

    if (( changes == 0 )); then
        skip_step "All tuners present"
        return 0
    fi

    if [[ -n "$new_tuners" ]]; then
        insert_jellyfin_tuners "$updated_xml" "$new_tuners" > "$work_dir/next.xml"
        mv "$work_dir/next.xml" "$updated_xml"
    fi

    if ! grep -q "</TunerHosts>" "$updated_xml"; then
        warn_step "No <TunerHosts> section in livetv.xml — left unchanged"
        return 0
    fi

    run sudo docker stop "$JELLYFIN_CONTAINER"
    run sudo cp -p "$livetv_xml" "$livetv_xml.bak-$(date +%Y%m%d%H%M%S)"
    write_root_file "$livetv_xml" < "$updated_xml"
    run sudo docker start "$JELLYFIN_CONTAINER"

    print_info
    refresh_jellyfin_guide
}
