# Connect to ChulaWiFi in Linux 101

This is a copy-paste setup for Linux systems using `NetworkManager` with the `wpa_supplicant` OpenSSL backend, `systemd`, and `nmcli`. It modifies `NetworkManager` state and may disconnect the current Wi-Fi connection, so do not run it over an SSH session that depends on Wi-Fi.

## Why this is needed

ChulaWiFi uses WPA-Enterprise: reaching the access point is only the first step. Your device must then authenticate with the university's server. With PEAP, it first establishes an encrypted TLS tunnel, then uses your CUNET identity and password inside that tunnel with MSCHAPv2.

The legacy ChulaWiFi authentication server was checked and requires TLS 1.0 for that tunnel. Modern Linux clients reject this deprecated protocol by default, so authentication can fail before your password is checked. These defaults are intentional security protections, not a Linux bug. [OpenSSL's migration guide](https://docs.openssl.org/master/man7/ossl-guide-migration/) explains why TLS 1.0 requires security level 0. Depending on your distribution and Wi-Fi backend, the exact defaults can differ.

This mismatch can produce an `unsupported protocol` error followed by `EAP authentication failed`, even with the correct password. Re-entering your password or selecting PEAP/MSCHAPv2 alone will not fix a TLS policy mismatch. Other authentication failures can still have different causes.

### What this setup changes

The workaround enables older TLS settings for the ChulaWiFi profile only, while configuring certificate and domain checks to authenticate the server:

- PEAP version 0 with MSCHAPv2.
- TLS 1.0 compatibility using `phase1-auth-flags 0x20`.
- The Chula self-signed certificate and `wifi.it.chula.ac.th` domain are checked for server authentication.

[ArchWiki's NetworkManager guidance](https://wiki.archlinux.org/title/Networkmanager#WPA_Enterprise_connections_fail_to_authenticate_with_OpenSSL_%22unsupported_protocol%22_error) describes this error and the per-connection workaround. This profile uses `phase1-auth-flags 0x20` (decimal `32`) to explicitly enable TLS 1.0. It does not disable newer TLS versions or explicitly enable TLS 1.1.

When TLS 1.0 is explicitly enabled, [wpa_supplicant's OpenSSL implementation](https://android.googlesource.com/platform/external/wpa_supplicant_8/+/master/src/crypto/tls_openssl.c) automatically lowers the connection's OpenSSL security level as needed. A separate cipher override is therefore unnecessary for this implementation. The commands below clear any old override when updating an existing profile. The security relaxation still occurs, but only for this connection, not system-wide. This configuration was tested successfully on the author's system; other backends or builds may behave differently.

The certificate check is separate from TLS compatibility: it helps prevent a fake access point from impersonating the university and capturing your login. It does not make the older TLS protocols modern or secure. Skipping certificate verification removes that server identity protection.

This is a compatibility workaround, not the long-term fix. The institution should upgrade its authentication server to support modern TLS. Never lower the global OpenSSL policy or edit `/etc/ssl/openssl.cnf` for this setup. Chula IT lists Wi-Fi services on its [official Wi-Fi page](https://www.it.chula.ac.th/en/service/en-wifi/); check there for current availability and alternatives.

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

### 4. Install and check the Chula certificate

Download the certificate from [Chula's official Android setup instructions](https://www.it.chula.ac.th/wp-content/uploads/2021/12/ChulaWiFi-Android11.pdf) using your CUNET account. The `.cer` file is PEM-encoded, not DER. Set `CERT_FILE` to wherever you saved it, then inspect its subject, issuer, expiry, and SHA-256 fingerprint:

```bash
CERT_FILE='/path/to/wifiitchulaacth.cer' # Replace with the downloaded file's path.
openssl x509 -in "$CERT_FILE" -noout -subject -issuer -dates -fingerprint -sha256
```

The certificate tested with this guide has this SHA-256 fingerprint:

```text
54:6B:D9:2F:13:09:ED:9A:7C:76:35:00:96:FF:16:7D:A3:D0:42:9B:54:AB:CE:E8:09:E4:1B:75:FF:5E:6C:8F
```

If it differs, do not use it until you have verified the replacement with Chula IT. Install the verified public certificate:

```bash
CERT_PATH='/etc/NetworkManager/certs/chula-wifi.pem'
sudo install -Dm644 "$CERT_FILE" "$CERT_PATH"
```

NetworkManager uses this certificate as its trust anchor and applies the configured domain check.

### 5. Enter the CUNET identity

Enter the identity used by your CUNET Account. Replace the example value below with your own identity. Do not put the password in this command or in the README; NetworkManager will ask for it securely at activation time:

```bash
CHULA_IDENTITY='67xxxxxxxx' # Replace with your own CUNET identity.
```

### 6. Configure WPA-EAP and ChulaWiFi compatibility

Apply the Wi-Fi security settings. `PEAP` with inner `MSCHAPv2` is the authentication method; `phase1-auth-flags 0x20` explicitly enables the required TLS 1.0 compatibility. The empty `openssl-ciphers` value clears any previous cipher override, leaving policy adjustment to `wpa_supplicant`:

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
    802-1x.phase1-auth-flags 0x20 \
    802-1x.phase2-auth mschapv2 \
    802-1x.phase2-autheap '' \
    802-1x.openssl-ciphers '' \
    802-1x.ca-cert "$CERT_PATH" \
    802-1x.system-ca-certs no \
    802-1x.ca-path '' \
    802-1x.domain-match wifi.it.chula.ac.th \
    802-1x.password-flags 0 \
    802-1x.identity "$CHULA_IDENTITY" \
    802-11-wireless.mac-address-randomization never

unset CHULA_IDENTITY
```

Never set `DEFAULT@SECLEVEL=0` globally in `/etc/ssl/openssl.cnf`, and do not run a competing per-interface `wpa_supplicant` or `dhcpcd` setup.

### 7. Activate the profile

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

The certificate is required by default. Compare its fingerprint with the value in step 4, install it, and pass its path. The helper checks that it is a readable PEM certificate, then configures certificate/domain validation:

```bash
./setup-chulawifi.sh --cert-path /etc/NetworkManager/certs/chula-wifi.pem
```

It performs the same setup with automatic interface selection. Use `--interface NAME` to select a specific adapter, or `--profile NAME` to leave an existing profile untouched. The helper never stores credentials in the repository or passes the password as a command-line argument. If Chula rotates its certificate, verify the new fingerprint with IT before updating the value in step 4.

If you omit `--cert-path`, the helper asks before continuing without server certificate verification. A fake access point could impersonate Chula and capture your CUNET login; answer `y` only if you accept that risk. The default answer is no, which stops setup so you can install the certificate and rerun the command.

To skip the certificate confirmation, pass `--dangerously-skip-server-cert-verification`. This disables server certificate and domain checks. You still need an interactive terminal for your CUNET identity and password:

```bash
./setup-chulawifi.sh --dangerously-skip-server-cert-verification
```

`nmcli --ask` prompts for the password without putting it in the script or command arguments. Chula IT says that ChulaWiFi uses a CUNET Account; confirm the correct identity format and account eligibility if authentication fails.

## If it fails

Set `PROFILE` to the name you used, then inspect it without displaying its password:

```bash
PROFILE='ChulaWiFi' # Replace if you used a different profile name.
nmcli -g connection.id,connection.interface-name,802-1x.eap,802-1x.phase1-peapver,802-1x.phase1-auth-flags,802-1x.phase2-auth,802-1x.openssl-ciphers,802-1x.ca-cert,802-1x.domain-match connection show id "$PROFILE"
journalctl -u NetworkManager -b --no-pager | grep -Ei 'ChulaWiFi|wpa|802\.1x|eap|tls|openssl|fail' | tail -n 100
```

- If `ChulaWiFi` is not listed, check the radio, interface, range, or access point.
- If association succeeds but logs show TLS/cipher errors, confirm the PEAP settings and `phase1-auth-flags 0x20`, and check that NetworkManager uses the `wpa_supplicant` OpenSSL backend described above.
- If certificate verification fails, check the installed certificate path and SHA-256 fingerprint, and confirm the profile checks `wifi.it.chula.ac.th`.
- If there are no TLS errors, re-enter the CUNET identity/password and check the account with Chula IT.
- If authentication succeeds but there is no Internet access, inspect DHCP and campus service status.

NetworkManager should own the interface. Do not run a competing per-interface `wpa_supplicant` or `dhcpcd` setup at the same time.
