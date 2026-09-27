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

configure_jellyfin_tuners() {
    local livetv_xml
    local name
    local url
    local new_tuners=""
    local added_count=0
    local updated_xml

    livetv_xml="$(jellyfin_livetv_xml)"

    # Jellyfin writes livetv.xml on its first start, so a fresh
    # install has to be opened once (startup wizard) first.
    if [[ ! -f "$livetv_xml" ]]; then
        skip_step "Jellyfin not initialized yet — finish its startup wizard and run again"
        return 0
    fi

    while IFS="|" read -r name url; do
        [[ -z "$name" || "$name" == \#* ]] && continue

        if grep -qF "<Url>$(xml_escape "$url")</Url>" "$livetv_xml"; then
            print_info "⏭️ Already present: $name"
            continue
        fi

        print_info "➜ Adding tuner: $name ($url)"
        new_tuners+="$(jellyfin_tuner_xml "$name" "$url")"$'\n'
        added_count=$((added_count + 1))
    done < "$JELLYFIN_TUNERS_FILE"

    if (( added_count == 0 )); then
        skip_step "All tuners present"
        return 0
    fi

    updated_xml="$(make_work_dir jellyfin)/livetv.xml"
    insert_jellyfin_tuners "$livetv_xml" "$new_tuners" > "$updated_xml"

    if ! grep -q "</TunerHosts>" "$updated_xml"; then
        warn_step "No <TunerHosts> section in livetv.xml — left unchanged"
        return 0
    fi

    run sudo docker stop "$JELLYFIN_CONTAINER"
    run sudo cp -p "$livetv_xml" "$livetv_xml.bak-$(date +%Y%m%d%H%M%S)"
    write_root_file "$livetv_xml" < "$updated_xml"
    run sudo docker start "$JELLYFIN_CONTAINER"

    print_info
    print_info "Channels appear after Jellyfin's \"Refresh Guide\" task runs"
    print_info "(Dashboard > Scheduled Tasks)."
}
