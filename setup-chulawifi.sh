#!/usr/bin/env bash

set -Eeuo pipefail

readonly DEFAULT_PROFILE='ChulaWiFi'
readonly DEFAULT_SSID='ChulaWiFi'

PROFILE="$DEFAULT_PROFILE"
SSID="$DEFAULT_SSID"
IFACE=''

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: ./setup-chulawifi.sh [options]

Create or update a NetworkManager profile for ChulaWiFi and activate it.
The CUNET identity and password are requested interactively; credentials are
never stored in this script or passed as command-line arguments.

Options:
  -i, --interface NAME  Use this Wi-Fi interface instead of auto-detection.
  -p, --profile NAME    Use this NetworkManager profile name.
  -s, --ssid NAME       Use this Wi-Fi SSID.
  -h, --help            Show this help.

Examples:
  ./setup-chulawifi.sh
  ./setup-chulawifi.sh --interface wlp0s20f3
  ./setup-chulawifi.sh --profile ChulaWiFi-clean
USAGE
}

run_as_root() {
    if (( EUID == 0 )); then
        "$@"
        return
    fi

    command -v sudo >/dev/null 2>&1 || die 'sudo is required to start NetworkManager.'
    sudo "$@"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

interface_is_available() {
    local candidate=$1
    local device

    for device in "${WIFI_DEVICES[@]}"; do
        [[ "$device" == "$candidate" ]] && return 0
    done

    return 1
}

choose_interface() {
    local candidate

    if [[ -n "$IFACE" ]]; then
        interface_is_available "$IFACE" || die \
            "Wi-Fi interface '$IFACE' is not managed by NetworkManager."
        return
    fi

    case "${#WIFI_DEVICES[@]}" in
        0)
            printf '%s\n' 'No Wi-Fi device is managed by NetworkManager.' >&2
            nmcli device status >&2 || true
            die 'Connect or enable a Wi-Fi adapter, then run the script again.'
            ;;
        1)
            IFACE="${WIFI_DEVICES[0]}"
            ;;
        *)
            [[ -t 0 ]] || die \
                'Multiple Wi-Fi interfaces found; rerun with --interface NAME.'

            printf '%s\n' 'Multiple managed Wi-Fi interfaces found:'
            printf '  %s\n' "${WIFI_DEVICES[@]}"
            while true; do
                read -r -p 'Wi-Fi interface: ' candidate || die 'No interface selected.'
                if interface_is_available "$candidate"; then
                    IFACE="$candidate"
                    break
                fi
                printf "Unknown interface '%s'. Choose one of the listed interfaces.\n" \
                    "$candidate" >&2
            done
            ;;
    esac
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -i|--interface)
                (( $# >= 2 )) || die "$1 requires a value."
                IFACE=$2
                shift 2
                ;;
            -p|--profile)
                (( $# >= 2 )) || die "$1 requires a value."
                PROFILE=$2
                shift 2
                ;;
            -s|--ssid)
                (( $# >= 2 )) || die "$1 requires a value."
                SSID=$2
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                (( $# == 0 )) || die "Unexpected argument: $1"
                ;;
            *)
                die "Unknown option: $1 (use --help for usage)"
                ;;
        esac
    done

    [[ -n "$PROFILE" ]] || die 'The profile name cannot be empty.'
    [[ -n "$SSID" ]] || die 'The SSID cannot be empty.'
}

main() {
    local device_status
    local chula_identity
    local profile_type

    parse_args "$@"
    require_command nmcli
    require_command systemctl

    if systemctl is-active --quiet NetworkManager.service; then
        printf '%s\n' 'NetworkManager is already running.'
    else
        printf '%s\n' 'Starting NetworkManager...'
        run_as_root systemctl enable --now NetworkManager.service
    fi

    if ! nmcli general status >/dev/null; then
        die 'NetworkManager is not reachable over D-Bus.'
    fi

    nmcli radio wifi on

    if ! device_status="$(nmcli -t -f DEVICE,TYPE device status)"; then
        die 'Could not read Wi-Fi devices from NetworkManager.'
    fi

    mapfile -t WIFI_DEVICES < <(sed -n 's/:wifi$//p' <<<"$device_status")
    choose_interface

    printf 'Using Wi-Fi interface: %s\n' "$IFACE"
    printf 'Scanning for %s...\n' "$SSID"
    if ! nmcli device wifi list --rescan yes ifname "$IFACE"; then
        printf '%s\n' \
            'Warning: the Wi-Fi scan failed; continuing with profile setup.' >&2
    fi

    if nmcli connection show id "$PROFILE" >/dev/null 2>&1; then
        profile_type="$(nmcli -g connection.type connection show id "$PROFILE")"
        [[ "$profile_type" == '802-11-wireless' ]] || die \
            "Profile '$PROFILE' already exists but is not a Wi-Fi profile; use --profile NAME."
        printf "Updating existing NetworkManager profile '%s'.\n" "$PROFILE"
    else
        printf "Creating NetworkManager profile '%s'.\n" "$PROFILE"
        nmcli connection add type wifi ifname "$IFACE" \
            con-name "$PROFILE" ssid "$SSID"
    fi

    if [[ -t 0 ]]; then
        read -r -p 'CUNET identity: ' chula_identity || die 'No identity entered.'
    else
        die 'The CUNET identity must be entered interactively.'
    fi
    [[ -n "$chula_identity" ]] || die 'The CUNET identity cannot be empty.'

    nmcli connection modify "$PROFILE" \
        connection.interface-name "$IFACE" \
        connection.autoconnect no \
        connection.autoconnect-priority 100 \
        802-11-wireless.ssid "$SSID" \
        802-11-wireless-security.key-mgmt wpa-eap \
        802-11-wireless-security.auth-alg open \
        802-11-wireless-security.proto rsn \
        802-11-wireless-security.pairwise ccmp \
        802-1x.eap peap \
        802-1x.phase1-peapver 0 \
        802-1x.phase1-peaplabel '' \
        802-1x.phase1-auth-flags 0x60 \
        802-1x.phase2-auth mschapv2 \
        802-1x.phase2-autheap '' \
        802-1x.openssl-ciphers 'DEFAULT@SECLEVEL=0' \
        802-1x.password-flags 0 \
        802-1x.identity "$chula_identity" \
        802-11-wireless.mac-address-randomization never

    unset chula_identity

    printf '%s\n' 'Activating the connection. nmcli will ask for the CUNET password.'
    if ! nmcli --ask connection up "$PROFILE" ifname "$IFACE"; then
        die "Activation failed. Autoconnect remains disabled for '$PROFILE'."
    fi

    nmcli connection modify "$PROFILE" connection.autoconnect yes
    printf "Setup complete. '%s' will autoconnect when available.\n\n" "$PROFILE"
    nmcli connection show --active
    nmcli device status
}

main "$@"
