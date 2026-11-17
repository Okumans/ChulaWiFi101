# Connect to ChulaWiFi in Linux 101

This is a copy-paste setup for Linux systems using `NetworkManager`, `systemd`, and `nmcli`. It modifies `NetworkManager` state and may disconnect the current Wi-Fi connection, so do not run it over an SSH session that depends on Wi-Fi.

The first attempt failed after Wi-Fi association, during 802.1X authentication: modern OpenSSL rejected the older TLS/cipher requirements of the legacy ChulaWiFi service. The client policy was too strict; this was not necessarily a bad password. The setup enables the required legacy settings for this profile only:

The long-term fix is for the institution to upgrade its authentication tunnel to a modern TLS version. [ArchWiki's NetworkManager guidance](https://wiki.archlinux.org/title/Networkmanager#WPA_Enterprise_connections_fail_to_authenticate_with_OpenSSL_%22unsupported_protocol%22_error) describes this OpenSSL error and the per-connection workaround: `phase1-auth-flags=32` allows TLS 1.0, while `64` allows TLS 1.1. This profile uses `0x60` to allow both.

- PEAP version 0 with MSCHAPv2.
- TLS 1.0/1.1 compatibility using `phase1-auth-flags 0x60`.
- `DEFAULT@SECLEVEL=0` for the profile, not system-wide.

This weakens security for this one connection. Never lower the global OpenSSL policy or edit `/etc/ssl/openssl.cnf`. Chula IT still lists `ChulaWiFi` and alternatives on its [official Wi-Fi page](https://www.it.chula.ac.th/en/service/en-wifi/) as checked on 2026-08-05; if the service has since been retired, use `Eduroam` or `Chula-FreeWiFi` instead.

## Main setup

Run each step in the same interactive Bash terminal. This keeps the `IFACE`, `PROFILE`, and identity variables available for the later steps.

### 1. Prepare NetworkManager

Make sure the required command-line tools are installed. They are present on most Linux systems that use NetworkManager:

```bash
command -v nmcli
command -v systemctl
```

`nmcli` configures NetworkManager, `systemctl` manages the service, and the service name is `NetworkManager.service`.

Check the service status manually:

```bash
systemctl is-active NetworkManager.service
```

If the result is not `active`, start and enable NetworkManager:

```bash
sudo systemctl enable --now NetworkManager.service
```

Confirm that NetworkManager is reachable over D-Bus:

```bash
nmcli general status
```

If this fails, stop here and fix the service before continuing.

### 2. Turn on Wi-Fi and select the interface

Turn on the Wi-Fi radio and list the devices managed by NetworkManager:

```bash
nmcli radio wifi on
nmcli device status
```

Find the row whose type is `wifi`, then set `IFACE` to its device name. For example, replace the value below if your adapter has a different name:

```bash
IFACE='wlp0s20f3'
```

Check that the adapter can see nearby networks. The scan should include `ChulaWiFi` when you are in range:

```bash
nmcli device wifi list --rescan yes ifname "$IFACE"
```

### 3. Choose a NetworkManager profile

The profile name and SSID are normally both `ChulaWiFi`:

```bash
PROFILE='ChulaWiFi'
SSID='ChulaWiFi'
```

If you want to preserve an existing profile named `ChulaWiFi`, choose a new profile name such as `ChulaWiFi-clean` before continuing. Check whether the profile already exists:

```bash
nmcli connection show id "$PROFILE"
```

If NetworkManager says the profile does not exist, create it:

```bash
nmcli connection add type wifi ifname "$IFACE" con-name "$PROFILE" ssid "$SSID"
```

### 4. Enter the CUNET identity

Enter the identity used by your CUNET Account. Replace the example value below with your own identity. Do not put the password in this command or in the README; NetworkManager will ask for it securely at activation time:

```bash
CHULA_IDENTITY='67xxxxxxxx' # Replace with your own CUNET identity.
```

### 5. Configure WPA-EAP and ChulaWiFi compatibility

Apply the Wi-Fi security settings. `PEAP` with inner `MSCHAPv2` is the authentication method; `phase1-auth-flags 0x60` and profile-local `DEFAULT@SECLEVEL=0` provide compatibility with the legacy TLS requirements. The weaker TLS policy applies only to this profile:

```bash
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
    802-1x.identity "$CHULA_IDENTITY" \
    802-11-wireless.mac-address-randomization never

unset CHULA_IDENTITY
```

Never set `DEFAULT@SECLEVEL=0` globally in `/etc/ssl/openssl.cnf`, and do not run a competing per-interface `wpa_supplicant` or `dhcpcd` setup.

### 6. Activate the profile

Ask NetworkManager for the password, then enable autoconnect only if activation succeeds:

```bash
nmcli --ask connection up "$PROFILE" ifname "$IFACE" && nmcli connection modify "$PROFILE" connection.autoconnect yes
```

Autoconnect is enabled only after a successful activation. Confirm the result:

```bash
nmcli connection show --active
nmcli device status
```

## Optional helper script

If you prefer the same procedure with automatic interface detection, run this from the repository directory:

```bash
./setup-chulawifi.sh
```

It performs the same setup with automatic interface selection. Use `--interface NAME` to select a specific adapter, or `--profile NAME` to leave an existing profile untouched. The helper never stores credentials in the repository or passes the password as a command-line argument.

`nmcli --ask` prompts for the password without putting it in the script or command arguments. Chula IT says that ChulaWiFi uses a CUNET Account; confirm the correct identity format and account eligibility if authentication fails.

## If it fails

Inspect the profile without displaying its password:

```bash
nmcli -g connection.id,connection.interface-name,802-1x.eap,802-1x.phase1-peapver,802-1x.phase1-auth-flags,802-1x.phase2-auth,802-1x.openssl-ciphers connection show id ChulaWiFi
journalctl -u NetworkManager -b --no-pager | grep -Ei 'ChulaWiFi|wpa|802\.1x|eap|tls|openssl|fail' | tail -n 100
```

- If `ChulaWiFi` is not listed, check the radio, interface, range, or access point.
- If association succeeds but logs show TLS/cipher errors, confirm the three legacy settings in the setup above.
- If there are no TLS errors, re-enter the CUNET identity/password and check the account with Chula IT.
- If authentication succeeds but there is no Internet access, inspect DHCP and campus service status.

NetworkManager should own the interface. Do not run a competing per-interface `wpa_supplicant` or `dhcpcd` setup at the same time.
