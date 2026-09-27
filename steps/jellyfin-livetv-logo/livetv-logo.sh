#!/usr/bin/env bash
#
# Jellyfin Live TV logo: keeps the image of the Live TV tile
# (Home > My Media) set to the logo of the last channel
# watched.
#
# Polls Jellyfin's sessions; when a channel stops playing
# (playback stopped, or switched to another channel), its logo
# is uploaded as the Live TV view's Primary image — the same
# thing "Edit images" does in the web UI. Runs as a systemd
# service installed by the Jellyfin Live TV Logo step.
#
# Reads JELLYFIN_URL and JELLYFIN_API_KEY from the repo's
# config.sh.
#

set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_DIR

# shellcheck source=/dev/null
source "$REPO_DIR/config.sh"

if [[ -z "${JELLYFIN_URL:-}" || -z "${JELLYFIN_API_KEY:-}" ]]; then
    echo "❌ JELLYFIN_URL and JELLYFIN_API_KEY must be set in config.sh" >&2
    exit 1
fi

readonly POLL_SECONDS="${LIVETV_LOGO_POLL_SECONDS:-10}"

# Logos darker than this (0-255, average over their visible
# pixels) get a light background: Jellyfin's tiles are dark.
readonly DARK_LOGO_THRESHOLD=100
readonly LIGHT_BACKGROUND="0xE6E6E6"

WORK_DIR="$(mktemp -d -t livetv-logo.XXXXXX)"
readonly WORK_DIR
trap 'rm -rf "$WORK_DIR"' EXIT

log() {
    printf '%s\n' "$*"
}

# Calls the Jellyfin API.
#
# Arguments:
#   $1 - Path, with query string
#   $@ - Extra curl options
jellyfin() {
    local path="$1"
    shift

    curl -fsS --max-time 30 \
        -H "Authorization: MediaBrowser Token=\"$JELLYFIN_API_KEY\"" \
        "$@" "$JELLYFIN_URL$path"
}

# Prints the id of the Live TV view (the tile on the home
# screen). It is the same for every user.
livetv_view_id() {
    local user_id

    user_id="$(jellyfin /Users | jq -r '.[0].Id')"
    jellyfin "/UserViews?userId=$user_id" |
        jq -r 'first(.Items[] | select(.CollectionType == "livetv") | .Id) // empty'
}

# Prints the ids of the channels playing in any session,
# one per line.
playing_channels() {
    jellyfin "/Sessions?activeWithinSeconds=600" |
        jq -r '.[] | .NowPlayingItem | select(. != null and .Type == "TvChannel") | .Id'
}

channel_name() {
    jellyfin "/Items?ids=$1" | jq -r '.Items[0].Name // "unknown channel"'
}

# Prints the average of one ffmpeg signalstats value over an
# image run through a filter chain.
#
# Arguments:
#   $1 - Image
#   $2 - Filter chain before signalstats
image_average() {
    ffmpeg -loglevel error -i "$1" \
        -vf "$2,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-" \
        -f null - 2> /dev/null |
        grep -oP 'YAVG=\K[0-9.]+' | head -1
}

# Prints the average opacity (0-255) of an image.
image_opacity() {
    image_average "$1" "format=rgba,alphaextract"
}

# Prints the brightness (0-255) of a logo's visible pixels:
# the luma of the logo over black divided by its coverage.
logo_brightness() {
    local alpha
    local luma

    alpha="$(image_opacity "$1")"
    luma="$(image_average "$1" "format=rgba,premultiply=inplace=1,format=gray")"

    awk -v a="${alpha:-255}" -v y="${luma:-255}" \
        'BEGIN { if (a > 0) printf "%.0f\n", y / a * 255; else print 255 }'
}

# Prints the color of an image's top-left pixel as 0xRRGGBB.
corner_color() {
    ffmpeg -loglevel error -i "$1" -frames:v 1 -vf "crop=1:1:0:0,format=rgb24" \
        -f rawvideo - 2> /dev/null |
        od -An -tx1 | tr -d ' \n' | sed 's/^/0x/'
}

# Makes the tile image: the tile is 16:9 and crops the image to
# fill it, which cuts the sides off wide logos, so the logo is
# fitted inside a 16:9 canvas with a margin — transparent, light
# for a dark logo that would vanish on the dark tile, or the
# logo's own background color for an opaque logo.
#
# Arguments:
#   $1 - Logo
#   $2 - Output PNG
make_tile_image() {
    local background="black@0"
    local fit="scale=768:432:force_original_aspect_ratio=decrease,format=rgba,pad=1280:720:(ow-iw)/2:(oh-ih)/2:color=black@0"

    command -v ffmpeg > /dev/null || return 1

    # A fully opaque logo is a picture with its own background:
    # extend that background to the edges of the tile instead.
    if awk -v a="$(image_opacity "$1")" 'BEGIN { exit !(a >= 254.5) }'; then
        background="$(corner_color "$1")"
    elif (( $(logo_brightness "$1") < DARK_LOGO_THRESHOLD )); then
        background="$LIGHT_BACKGROUND"
    fi

    # The fitted logo is laid over a full canvas, so its own
    # transparent areas show the background too.
    ffmpeg -loglevel error -y -i "$1" -frames:v 1 \
        -filter_complex "color=c=$background:s=1280x720,format=rgba[bg];[0:v]${fit}[fg];[bg][fg]overlay=format=auto:shortest=1" \
        -f image2 -c:v png "$2" 2> /dev/null
}

# Uploads a channel's logo as the Live TV view image.
#
# Arguments:
#   $1 - Live TV view id
#   $2 - Channel id
apply_channel_logo() {
    local view_id="$1"
    local channel_id="$2"
    local logo="$WORK_DIR/logo"
    local headers="$WORK_DIR/headers"
    local content_type

    if ! jellyfin "/Items/$channel_id/Images/Primary" -D "$headers" -o "$logo" 2> /dev/null; then
        log "⏭️ $(channel_name "$channel_id") has no logo"
        return 0
    fi

    content_type="$(awk -F': *' 'tolower($1) == "content-type" { print $2 }' "$headers" | tr -d '\r' | tail -1)"

    if make_tile_image "$logo" "$WORK_DIR/tile.png"; then
        logo="$WORK_DIR/tile.png"
        content_type="image/png"
    fi

    # Jellyfin expects the image base64-encoded in the request body.
    # (Called from an if, so errexit is off here: check explicitly.)
    if ! base64 -w 0 "$logo" |
        jellyfin "/Items/$view_id/Images/Primary" \
            -X POST -H "Content-Type: ${content_type:-image/png}" --data-binary @- > /dev/null; then
        log "❌ Upload failed for $(channel_name "$channel_id")"
        return 1
    fi

    log "✅ Live TV logo: $(channel_name "$channel_id")"
}

main() {
    local view_id=""
    local previous=""
    local current
    local stopped
    local applied=""

    log "Watching Live TV playback on $JELLYFIN_URL every ${POLL_SECONDS}s"

    while true; do
        # Jellyfin may still be starting or restarting.
        if [[ -z "$view_id" ]]; then
            view_id="$(livetv_view_id 2> /dev/null || true)"
        fi

        if [[ -n "$view_id" ]] && current="$(playing_channels 2> /dev/null)"; then
            # The last channel that was playing before and isn't anymore.
            stopped="$(grep -vxF -f <(printf '%s\n' "$current") <<< "$previous" | tail -1 || true)"

            if [[ -n "$stopped" && "$stopped" != "$applied" ]]; then
                if apply_channel_logo "$view_id" "$stopped"; then
                    applied="$stopped"
                fi
            fi

            previous="$current"
        fi

        sleep "$POLL_SECONDS"
    done
}

# Run only when executed, so the functions can be sourced for testing.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
