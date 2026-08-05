# Connect to ChulaWiFi in Linux 101

This is a copy-paste setup for Linux systems using `NetworkManager`, `systemd`, and `nmcli`. It modifies `NetworkManager` state and may disconnect the current Wi-Fi connection, so do not run it over an SSH session that depends on Wi-Fi.

The first attempt failed after Wi-Fi association, during 802.1X authentication: modern OpenSSL rejected the older TLS/cipher requirements of the legacy ChulaWiFi service. The client policy was too strict; this was not necessarily a bad password. The script enables the required legacy settings for this profile only:

- PEAP version 0 with MSCHAPv2.
- TLS 1.0/1.1 compatibility using `phase1-auth-flags 0x60`.
- `DEFAULT@SECLEVEL=0` for the profile, not system-wide.

This weakens security for this one connection. Never lower the global OpenSSL policy or edit `/etc/ssl/openssl.cnf`. Chula IT still lists `ChulaWiFi` and alternatives on its [official Wi-Fi page](https://www.it.chula.ac.th/en/service/en-wifi/) as checked on 2026-08-05; if the service has since been retired, use `Eduroam` or `Chula-FreeWiFi` instead.

## Run the setup

Paste this whole block into an interactive Bash terminal. It detects the Wi-Fi interface, creates or updates the `ChulaWiFi` profile, asks for the identity and password, and activates the connection.

```bash
set -euo pipefail

sudo systemctl enable --now NetworkManager.service
nmcli general status >/dev/null

PROFILE='ChulaWiFi' # Change to ChulaWiFi-clean to keep an existing profile untouched.

mapfile -t WIFI_DEVICES < <(
    nmcli -t -f DEVICE,TYPE device status | sed -n 's/:wifi$//p'
)

case "${#WIFI_DEVICES[@]}" in
    0)
        echo 'No Wi-Fi device is managed by NetworkManager.' >&2
        nmcli device status
        exit 1
        ;;
    1)
        IFACE="${WIFI_DEVICES[0]}"
        ;;
    *)
        echo 'Select the Wi-Fi interface:'
        PS3='Interface: '
        select IFACE in "${WIFI_DEVICES[@]}"; do
            [[ -n "$IFACE" ]] && break
        done
        ;;
esac

echo "Using Wi-Fi interface: $IFACE"
nmcli radio wifi on
nmcli device wifi list --rescan yes ifname "$IFACE"

nmcli connection show id "$PROFILE" >/dev/null 2>&1 || \
    nmcli connection add type wifi ifname "$IFACE" \
        con-name "$PROFILE" ssid ChulaWiFi

read -r -p 'CUNET identity: ' CHULA_IDENTITY

nmcli connection modify "$PROFILE" \
    connection.interface-name "$IFACE" \
    connection.autoconnect no \
    connection.autoconnect-priority 100 \
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
    802-1x.identity "$CHULA_IDENTITY" \
    802-11-wireless.mac-address-randomization never

unset CHULA_IDENTITY
nmcli --ask connection up "$PROFILE" ifname "$IFACE"
nmcli connection modify "$PROFILE" connection.autoconnect yes

nmcli connection show --active
nmcli device status
```

`nmcli --ask` prompts for the password without putting it in the script or command arguments. Chula IT says that ChulaWiFi uses a CUNET Account; confirm the correct identity format and account eligibility if authentication fails.

## If it fails

Inspect the profile without displaying its password:

```bash
nmcli -g connection.id,connection.interface-name,802-1x.eap,802-1x.phase1-peapver,802-1x.phase1-auth-flags,802-1x.phase2-auth,802-1x.openssl-ciphers connection show id ChulaWiFi
journalctl -u NetworkManager -b --no-pager | grep -Ei 'ChulaWiFi|wpa|802\.1x|eap|tls|openssl|fail' | tail -n 100
```

- If `ChulaWiFi` is not listed, check the radio, interface, range, or access point.
- If association succeeds but logs show TLS/cipher errors, confirm the three legacy settings in the script.
- If there are no TLS errors, re-enter the CUNET identity/password and check the account with Chula IT.
- If authentication succeeds but there is no Internet access, inspect DHCP and campus service status.

NetworkManager should own the interface. Do not run a competing per-interface `wpa_supplicant` or `dhcpcd` setup at the same time.
