#!/usr/bin/env bash
# MaksAI Web VPS bootstrap for Ubuntu 24.04 x86_64.
# Keeps existing services untouched. Requires prebuilt release.
set -Eeuo pipefail
umask 077

say() { printf '\n[MaksAI] %s\n' "$*"; }
fail() { printf '\n[MaksAI] ERROR: %s\n' "$*" >&2; exit 1; }
trap 'status=$?; if (( status != 0 )); then printf "\n[MaksAI] Installation stopped (code %s). Existing services were not intentionally stopped.\n" "$status" >&2; fi' EXIT

[[ "$EUID" == 0 ]] || fail 'Run as root (or sudo bash install.sh).'
[[ "$(uname -m)" == 'x86_64' ]] || fail 'This installer supports x86_64 only.'
[[ -r /etc/os-release ]] || fail 'Cannot identify Linux distribution.'
# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == 'ubuntu' ]] || fail 'Only Ubuntu is supported.'
command -v curl >/dev/null || fail 'curl is required; install curl first.'
command -v tar >/dev/null || fail 'tar is required.'
command -v sha256sum >/dev/null || fail 'sha256sum is required.'
command -v systemctl >/dev/null || fail 'systemd is required.'

RELEASE_BASE='https://github.com/wakcuw53/wakcuw53/releases/download/maksai-web-v0.1'
RELEASE='zcode-3.14.3.tar.gz'
NODE_BASE='https://nodejs.org/dist/v24.14.0'
NODE_ARCHIVE='node-v24.14.0-linux-x64.tar.xz'
APP_ROOT='/opt/maksai-web'
STATE='/var/lib/maksai-web'
TOKEN_FILE='/etc/maksai-web/access-token'
UNIT='/etc/systemd/system/maksai-web.service'
TUNNEL_UNIT='/etc/systemd/system/maksai-web-tunnel.service'

[[ ! -f "$UNIT" ]] || grep -q 'Managed by MaksAI Web installer' "$UNIT" || fail 'A non-MaksAI service already has the name maksai-web.service; refusing to overwrite it.'
TMP="$(mktemp -d /tmp/maksai-installer.XXXXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap 'status=$?; cleanup; if (( status != 0 )); then printf "\n[MaksAI] Installation stopped (code %s). Existing programs remain untouched.\n" "$status" >&2; fi' EXIT

say 'Step 1/6: Checking prebuilt Web runtime...'
# Download first, before making persistent changes. Do not build 1800 packages on a 1 GB VPS.
curl -fL --retry 2 --connect-timeout 20 "$RELEASE_BASE/sha256.txt" -o "$TMP/sha256.txt" || fail 'Linux build is not published yet. Try later; nothing was changed.'
curl -fL --retry 2 --connect-timeout 20 "$RELEASE_BASE/$RELEASE" -o "$TMP/$RELEASE" || fail 'Cannot download the published Linux runtime.'
(cd "$TMP" && sha256sum -c sha256.txt) || fail 'Download checksum FAILED; will not install.'

say 'Step 2/6: Downloading isolated Node 24 runtime...'
curl -fL --retry 2 --connect-timeout 20 "$NODE_BASE/SHASUMS256.txt" -o "$TMP/node-sha256sums.txt" || fail 'Cannot fetch official Node checksums.'
curl -fL --retry 2 --connect-timeout 20 "$NODE_BASE/$NODE_ARCHIVE" -o "$TMP/$NODE_ARCHIVE" || fail 'Cannot fetch Node archive.'
expected="$(awk -v name="$NODE_ARCHIVE" '$2 == name {print $1}' "$TMP/node-sha256sums.txt")"
[[ "${#expected}" -eq 64 ]] || fail 'Official Node checksum is missing.'
actual="$(sha256sum "$TMP/$NODE_ARCHIVE" | cut -d' ' -f1)"
[[ "$expected" == "$actual" ]] || fail 'Node checksum mismatch.'

say 'Step 3/6: Checking available disk and swap...'
free_disk_kb="$(df -Pk / | awk 'END {print $4}')"
[[ "$free_disk_kb" =~ ^[0-9]+$ ]] || fail 'Cannot check disk.'
(( free_disk_kb > 4500000 )) || fail 'Need at least about 4.5 GB free disk for a safe install and 2 GB swap.'
mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
swap_kb="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo)"
if (( mem_kb < 2097152 && swap_kb < 1572864 )); then
  say 'Small VPS detected. Adding a 2 GB swap file without touching existing swap.'
  swap_path='/swapfile-maksai-web'
  if [[ ! -f "$swap_path" ]]; then
    fallocate -l 2G "$swap_path" || fail 'Could not allocate swap; please upgrade VPS RAM.'
    chmod 600 "$swap_path"
    mkswap "$swap_path" >/dev/null
  fi
  if ! swapon --show=NAME --noheadings | grep -Fxq "$swap_path"; then
    swapon "$swap_path" || fail 'Cannot activate swap.'
  fi
  if ! grep -qF "$swap_path none swap sw 0 0" /etc/fstab; then
    printf '\n%s none swap sw 0 0\n' "$swap_path" >> /etc/fstab
  fi
fi

say 'Step 4/6: Installing MaksAI under a separate directory...'
id -u maksai-web >/dev/null 2>&1 || useradd --system --home-dir "$STATE" --create-home --shell /usr/sbin/nologin maksai-web
install -d -o maksai-web -g maksai-web -m 750 "$STATE" "$STATE/workspace"
install -d -m 755 "$APP_ROOT" "$APP_ROOT/node" "$APP_ROOT/runtime"
tar -xJf "$TMP/$NODE_ARCHIVE" -C "$APP_ROOT/node" --strip-components=1 || fail 'Cannot unpack Node.'
[[ -x "$APP_ROOT/node/bin/node" ]] || fail 'Node executable not found.'
# Extract in a staging directory; never write outside our dedicated app root.
install -d -m 755 "$APP_ROOT/new-runtime"
tar -xzf "$TMP/$RELEASE" -C "$APP_ROOT/new-runtime" || fail 'Cannot unpack MaksAI Web.'
[[ -f "$APP_ROOT/new-runtime/zcode/bin/zcode.mjs" ]] || fail 'Unexpected distribution layout (missing zcode/bin/zcode.mjs).'
if [[ -d "$APP_ROOT/runtime/zcode" ]]; then mv "$APP_ROOT/runtime/zcode" "$APP_ROOT/runtime/zcode.previous.$(date +%s)"; fi
mv "$APP_ROOT/new-runtime/zcode" "$APP_ROOT/runtime/zcode"
rmdir "$APP_ROOT/new-runtime" || true

say 'Step 5/6: Creating a private systemd service...'
install -d -m 750 /etc/maksai-web
chown root:maksai-web /etc/maksai-web
if [[ ! -s "$TOKEN_FILE" ]]; then
  token="$(openssl rand -hex 24 2>/dev/null || tr -dc 'A-Fa-f0-9' </dev/urandom | head -c 48)"
  [[ "${#token}" -eq 48 ]] || fail 'Could not generate access token.'
  printf '%s' "$token" > "$TOKEN_FILE"
fi
chown root:maksai-web "$TOKEN_FILE"
chmod 640 "$TOKEN_FILE"
# Pick port without changing the ports of x-ui, Omnix, other services.
port=3030
if [[ ! -f /etc/maksai-web/port ]]; then
  if command -v ss >/dev/null && ss -Hltna | grep -Eq ':3030[[:space:]]'; then port=31459; fi
  printf '%s\n' "$port" > /etc/maksai-web/port
fi
chown root:maksai-web /etc/maksai-web/port
chmod 640 /etc/maksai-web/port
port="$(cat /etc/maksai-web/port)"
[[ "$port" =~ ^[0-9]{2,5}$ ]] || fail 'Invalid stored MaksAI port.'
install -d -m 755 "$APP_ROOT/bin"
cat > "$APP_ROOT/bin/start.sh" <<'WRAPPER'
#!/usr/bin/env bash
set -Eeuo pipefail
exec /opt/maksai-web/node/bin/node /opt/maksai-web/runtime/zcode/bin/zcode.mjs --web --host 127.0.0.1 --port "$(cat /etc/maksai-web/port)" --workspace /var/lib/maksai-web/workspace --no-open --token "$(cat /etc/maksai-web/access-token)"
WRAPPER
chmod 755 "$APP_ROOT/bin/start.sh"
cat > "$UNIT" <<'SERVICE'
# Managed by MaksAI Web installer — separate from OmnixAI and other services.
[Unit]
Description=MaksAI Web workspace (local access only)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=maksai-web
Group=maksai-web
WorkingDirectory=/var/lib/maksai-web
Environment=HOME=/var/lib/maksai-web
Environment=NODE_ENV=production
Environment=PATH=/opt/maksai-web/node/bin:/usr/bin:/bin
ExecStart=/opt/maksai-web/bin/start.sh
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
MemoryHigh=380M
MemoryMax=600M
MemorySwapMax=2G
Nice=10

[Install]
WantedBy=multi-user.target
SERVICE
systemctl daemon-reload
systemctl enable --now maksai-web.service >/dev/null
# On reruns: the service should run the new version.
systemctl restart maksai-web.service
sleep 4
if ! systemctl is-active --quiet maksai-web.service; then
  journalctl -u maksai-web.service --no-pager -n 30 || true
  fail 'MaksAI Web did not start; see log above.'
fi

say 'Step 6/6: Trying a separate Cloudflare Quick Tunnel for phone access...'
tunnel_url=''
if command -v cloudflared >/dev/null; then
  cfbin="$(command -v cloudflared)"
  if [[ ! -f "$TUNNEL_UNIT" ]] || grep -q 'Managed by MaksAI Web installer' "$TUNNEL_UNIT"; then
    cat > "$TUNNEL_UNIT" <<SERVICE
# Managed by MaksAI Web installer. Does not change the existing cloudflared service/config.
[Unit]
Description=Temporary HTTPS URL for MaksAI Web
After=network-online.target maksai-web.service
Wants=network-online.target

[Service]
Type=simple
User=maksai-web
Group=maksai-web
WorkingDirectory=/var/lib/maksai-web
ExecStart=$cfbin --config /dev/null tunnel --no-autoupdate --url http://127.0.0.1:$port
Restart=on-failure
RestartSec=12

[Install]
WantedBy=multi-user.target
SERVICE
    systemctl daemon-reload
    systemctl enable --now maksai-web-tunnel.service >/dev/null || true
    sleep 7
    tunnel_url="$(journalctl -u maksai-web-tunnel.service --no-pager --since '5 minutes ago' 2>/dev/null | grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | tail -1 || true)"
  fi
fi

printf '\n==========================================================\n'
printf 'MAKSAI WEB INSTALLED!\n'
printf 'Service:       systemctl status maksai-web\n'
printf 'Local address: http://127.0.0.1:%s\n' "$port"
if [[ -n "$tunnel_url" ]]; then
  printf 'PHONE HTTPS URL: %s/?token=%s\n' "$tunnel_url" "$(cat "$TOKEN_FILE")"
  printf 'Temporary quick-tunnel link may change after a restart.\n'
else
  printf 'No temporary HTTPS tunnel URL obtained.\n'
  printf 'You will need Tailscale HTTPS / Cloudflare domain to connect a phone.\n'
fi
printf 'Existing OmnixAI, x-ui, Docker, Tailscale and Cloudflare services were not changed.\n'
printf '==========================================================\n'