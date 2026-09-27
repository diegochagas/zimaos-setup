#!/usr/bin/env bash

set -Eeuo pipefail

########################################
# Jellyfin Live TV tuners
#
# Adds the M3U tuners listed in config/jellyfin-tuners.txt
# to Jellyfin's livetv.xml, skipping the ones already
# present (matched by URL). Jellyfin is stopped while the
# file is edited and started again afterwards, only when
# something changed.
#
# Runs on the ZimaOS server as root: livetv.xml belongs to
# the container user and docker needs root.
########################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

CONFIG_FILE="$SCRIPT_DIR/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ config.sh not found."
    echo "   Copy config.sh.example to config.sh and fill in the values,"
    echo "   or restore the filled-in copy from the Credentials folder."
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

if [[ -z "${APPDATA_ROOT:-}" ]]; then
    echo "❌ Missing value in config.sh: APPDATA_ROOT"
    exit 1
fi

readonly TUNERS_FILE="$SCRIPT_DIR/config/jellyfin-tuners.txt"
readonly LIVETV_XML="$APPDATA_ROOT/jellyfin/config/livetv.xml"
readonly CONTAINER="jellyfin"

DRY_RUN=false

print_help() {
    cat << EOF
Adds the M3U tuners from config/jellyfin-tuners.txt to Jellyfin.

Usage:
    sudo ./jellyfin-tuners.sh [--dry-run]

Options:
    --dry-run           List the tuners that would be added.
    --help              Show help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;

        --help)
            print_help
            exit 0
            ;;

        *)
            echo "❌ Unknown argument: $1"
            echo
            echo "Run './jellyfin-tuners.sh --help' for usage information."
            exit 1
            ;;
    esac
done

if [[ "$DRY_RUN" == false && $EUID -ne 0 ]]; then
    echo "❌ Run as root: sudo ./jellyfin-tuners.sh"
    exit 1
fi

# Jellyfin writes livetv.xml on its first start, so a fresh
# install has to be opened once (startup wizard) before this runs.
if [[ ! -f "$LIVETV_XML" ]]; then
    echo "❌ $LIVETV_XML not found."
    echo "   Start Jellyfin and finish its startup wizard first."
    exit 1
fi

########################################
# Escapes a value for use as XML text.
#
# Arguments:
#   $1 - Value
########################################
xml_escape() {
    local value="$1"
    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    printf '%s' "$value"
}

########################################
# Prints one <TunerHostInfo> element with Jellyfin's
# defaults for an M3U tuner (same values the web UI saves).
#
# Arguments:
#   $1 - Friendly name
#   $2 - Playlist URL
########################################
tuner_xml() {
    local name url id
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

NEW_TUNERS=""
added_count=0

while IFS="|" read -r name url; do
    [[ -z "$name" || "$name" == \#* ]] && continue

    if grep -qF "<Url>$(xml_escape "$url")</Url>" "$LIVETV_XML"; then
        echo "⏭️ Already present: $name"
        continue
    fi

    echo "➜ Adding: $name ($url)"
    NEW_TUNERS+="$(tuner_xml "$name" "$url")"$'\n'
    added_count=$((added_count + 1))
done < "$TUNERS_FILE"

if [[ $added_count -eq 0 ]]; then
    echo "✅ Nothing to add."
    exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
    echo "✅ $added_count tuner(s) would be added (dry-run)."
    exit 0
fi

docker stop "$CONTAINER" > /dev/null
cp -p "$LIVETV_XML" "$LIVETV_XML.bak-$(date +%Y%m%d%H%M%S)"

# Tuners go right before </TunerHosts>; an empty list is saved
# as <TunerHosts />, which is first expanded into an open/close pair.
updated_xml="$(mktemp)"
NEW_TUNERS="$NEW_TUNERS" awk '
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
' "$LIVETV_XML" > "$updated_xml"

if ! grep -q "</TunerHosts>" "$updated_xml"; then
    rm -f "$updated_xml"
    docker start "$CONTAINER" > /dev/null
    echo "❌ No <TunerHosts> section in $LIVETV_XML — left unchanged."
    exit 1
fi

# cat keeps the original owner and mode of livetv.xml.
cat "$updated_xml" > "$LIVETV_XML"
rm -f "$updated_xml"

docker start "$CONTAINER" > /dev/null

echo "✅ $added_count tuner(s) added, Jellyfin restarted."
echo "   Channels appear after the \"Refresh Guide\" task runs"
echo "   (Dashboard → Scheduled Tasks)."
