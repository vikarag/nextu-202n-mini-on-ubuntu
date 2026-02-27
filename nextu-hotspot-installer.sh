#!/bin/bash
# =============================================================================
# NEXTU 202N Mini WiFi Hotspot Installer
# =============================================================================
# Automatically installs the RTL8188EUS driver with AP mode support and
# configures a WiFi hotspot on Ubuntu systems.
#
# Supported: Ubuntu 22.04+ with kernel 5.15 - 6.17+
# Hardware:  NEXTU 202N Mini (Realtek RTL8188EUS, USB ID 0bda:8179)
#
# Usage:
#   chmod +x nextu-hotspot-installer.sh
#   sudo ./nextu-hotspot-installer.sh install
#   sudo ./nextu-hotspot-installer.sh uninstall
#   sudo ./nextu-hotspot-installer.sh configure
# =============================================================================

set -euo pipefail

VERSION="1.0.0"
DRIVER_REPO="https://github.com/aircrack-ng/rtl8188eus.git"
DRIVER_NAME="realtek-rtl8188eus"
DRIVER_VERSION="5.3.9~20221105"
CONF_DIR="/etc/nextu-hotspot"
SCRIPT_PATH="/usr/local/bin/nextu-hotspot"
BLACKLIST_FILE="/etc/modprobe.d/blacklist-rtl8xxxu.conf"
USB_ID="0bda:8179"

# Default hotspot settings
DEFAULT_SSID="NEXTU-Hotspot"
DEFAULT_PASSWORD="nextu2024"
DEFAULT_CHANNEL="6"
DEFAULT_SUBNET="192.168.50"
DEFAULT_COUNTRY="US"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ─── Pre-flight Checks ──────────────────────────────────────────────────────

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root (sudo)"
        exit 1
    fi
}

check_ubuntu() {
    if ! grep -qi 'ubuntu\|debian' /etc/os-release 2>/dev/null; then
        log_warn "This script is designed for Ubuntu/Debian. Proceeding anyway..."
    fi
}

check_adapter() {
    if lsusb | grep -q "$USB_ID"; then
        log_ok "NEXTU 202N Mini WiFi adapter detected (RTL8188EUS)"
        return 0
    else
        log_warn "NEXTU 202N adapter not detected (USB $USB_ID)"
        log_warn "The driver will still be installed for when the adapter is plugged in."
        return 0
    fi
}

detect_interface() {
    # Find the wireless interface name for the RTL8188EUS adapter
    local iface=""
    for dev in /sys/class/net/wl*; do
        [ -e "$dev" ] || continue
        local devname=$(basename "$dev")
        local driver_path=$(readlink -f "$dev/device/driver" 2>/dev/null)
        local uevent=$(cat "$dev/device/uevent" 2>/dev/null)
        if echo "$uevent" | grep -q "8188eu\|rtl8xxxu"; then
            iface="$devname"
            break
        fi
        # Also check by USB product ID
        if echo "$uevent" | grep -qi "bda/8179"; then
            iface="$devname"
            break
        fi
    done

    if [ -z "$iface" ]; then
        # Fallback: find any wl* interface
        iface=$(ip -o link show | awk -F': ' '/wl/{print $2}' | head -1)
    fi

    echo "$iface"
}

get_upstream_interface() {
    # Find the primary internet-connected interface (not wireless, not loopback)
    ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1
}

get_kernel_major() {
    uname -r | cut -d. -f1
}

get_kernel_minor() {
    uname -r | cut -d. -f2
}

kernel_gte() {
    # Check if running kernel >= $1.$2
    local major=$1 minor=$2
    local kmaj=$(get_kernel_major) kmin=$(get_kernel_minor)
    [ "$kmaj" -gt "$major" ] || { [ "$kmaj" -eq "$major" ] && [ "$kmin" -ge "$minor" ]; }
}

# ─── Driver Installation ────────────────────────────────────────────────────

install_dependencies() {
    log_info "Installing build dependencies..."
    apt-get update -qq
    apt-get install -y build-essential dkms git iw hostapd dnsmasq \
        linux-headers-"$(uname -r)" pkg-config 2>&1 | tail -5
    # Stop dnsmasq system service (we manage our own instance)
    systemctl stop dnsmasq 2>/dev/null || true
    systemctl disable dnsmasq 2>/dev/null || true
    log_ok "Dependencies installed"
}

clone_driver() {
    log_info "Cloning RTL8188EUS driver source..."
    local tmpdir="/tmp/rtl8188eus-build"
    rm -rf "$tmpdir"
    git clone --depth 1 "$DRIVER_REPO" "$tmpdir" 2>&1 | tail -3
    echo "$tmpdir"
}

apply_patches() {
    local srcdir="$1"
    log_info "Applying kernel compatibility patches..."

    # ── Patch 1: EXTRA_CFLAGS → ccflags-y (kernel 6.4+) ──
    if kernel_gte 6 4; then
        log_info "  Patch 1/4: EXTRA_CFLAGS → ccflags-y (kernel 6.4+)"
        sed -i 's/^EXTRA_CFLAGS += /ccflags-y += /g' "$srcdir/Makefile"
        sed -i 's/^EXTRA_LDFLAGS += /ldflags-y += /g' "$srcdir/Makefile"
        # Remove broken $(srctree)/$(src) include paths
        sed -i 's|-I$(srctree)/$(src)/include||g' "$srcdir/Makefile"
        sed -i 's|-I$(srctree)/$(src)/platform||g' "$srcdir/Makefile"
        sed -i 's|-I$(srctree)/$(src)/hal/btc||g' "$srcdir/Makefile"
        sed -i 's|-I$(srctree)/$(src)/hal/phydm||g' "$srcdir/Makefile"
    fi

    # ── Patch 2: del_timer_sync → timer_delete_sync (kernel 6.2+) ──
    if kernel_gte 6 2; then
        log_info "  Patch 2/4: del_timer_sync → timer_delete_sync (kernel 6.2+)"
        sed -i 's/del_timer_sync/timer_delete_sync/g' \
            "$srcdir/include/osdep_service_linux.h"
    fi

    # ── Patch 3: from_timer → timer_container_of (kernel 6.16+) ──
    # Only replace in header files where it's used as a macro call
    if ! grep -q 'from_timer' /usr/src/linux-headers-"$(uname -r)"/include/linux/timer.h 2>/dev/null; then
        log_info "  Patch 3/4: from_timer → timer_container_of"
        sed -i 's/from_timer/timer_container_of/g' \
            "$srcdir/include/osdep_service_linux.h"
    fi

    # ── Patch 4: cfg80211 MLO parameter changes (kernel 6.17+) ──
    if kernel_gte 6 17; then
        log_info "  Patch 4/4: cfg80211 MLO parameters (kernel 6.17+)"
        local cfg="$srcdir/os_dep/linux/ioctl_cfg80211.c"

        # set_wiphy_params: add int radio_idx
        sed -i 's/static int cfg80211_rtw_set_wiphy_params(struct wiphy \*wiphy, u32 changed)/static int cfg80211_rtw_set_wiphy_params(struct wiphy *wiphy, int radio_idx, u32 changed)/' "$cfg"

        # set_txpower: add int radio_idx after wdev
        # Find the line with "struct wireless_dev *wdev," inside set_txpower function
        local line_num=$(grep -n 'static int cfg80211_rtw_set_txpower' "$cfg" | head -1 | cut -d: -f1)
        if [ -n "$line_num" ]; then
            local wdev_line=$((line_num + 2))
            sed -i "${wdev_line}s/struct wireless_dev \*wdev,/struct wireless_dev *wdev, int radio_idx,/" "$cfg"
        fi

        # get_txpower: add int radio_idx, unsigned int link_id before int *dbm
        sed -i '/static int cfg80211_rtw_get_txpower/,/^{/{
            s/int \*dbm)/int radio_idx, unsigned int link_id, int *dbm)/
        }' "$cfg"

        # set_monitor_channel: add struct net_device *dev
        sed -i 's/static int cfg80211_rtw_set_monitor_channel(struct wiphy \*wiphy/static int cfg80211_rtw_set_monitor_channel(struct wiphy *wiphy, struct net_device *dev/' "$cfg"
    fi

    log_ok "All patches applied"
}

install_driver_dkms() {
    local srcdir="$1"
    local dkms_dest="/usr/src/${DRIVER_NAME}-${DRIVER_VERSION}"

    # Remove existing DKMS installation if present
    dkms remove -m "$DRIVER_NAME" -v "$DRIVER_VERSION" --all 2>/dev/null || true
    rm -rf "$dkms_dest"

    log_info "Installing driver source to $dkms_dest..."
    cp -r "$srcdir" "$dkms_dest"

    log_info "Building driver with DKMS..."
    dkms add -m "$DRIVER_NAME" -v "$DRIVER_VERSION" 2>&1 | grep -v "Deprecated"
    dkms build -m "$DRIVER_NAME" -v "$DRIVER_VERSION" 2>&1 | grep -v "Deprecated"
    dkms install -m "$DRIVER_NAME" -v "$DRIVER_VERSION" 2>&1 | grep -v "Deprecated"

    log_ok "Driver installed via DKMS (survives kernel updates)"
}

blacklist_old_driver() {
    log_info "Blacklisting old rtl8xxxu driver..."
    echo "blacklist rtl8xxxu" > "$BLACKLIST_FILE"
    log_ok "Old driver blacklisted at $BLACKLIST_FILE"
}

load_new_driver() {
    log_info "Loading new 8188eu driver..."
    rmmod rtl8xxxu 2>/dev/null || true
    rmmod 8188eu 2>/dev/null || true
    sleep 1
    modprobe 8188eu
    sleep 2

    if lsmod | grep -q 8188eu; then
        log_ok "Driver 8188eu loaded successfully"
    else
        log_error "Failed to load 8188eu driver"
        return 1
    fi

    # Verify AP mode support
    if iw phy 2>/dev/null | grep -q "* AP"; then
        log_ok "AP mode is supported"
    else
        log_warn "AP mode not detected in iw output (may still work)"
    fi
}

# ─── Hotspot Configuration ──────────────────────────────────────────────────

install_hotspot_configs() {
    local iface="$1"
    local ssid="$2"
    local password="$3"
    local channel="$4"
    local subnet="$5"
    local country="$6"
    local upstream="$7"

    mkdir -p "$CONF_DIR"

    log_info "Writing hostapd configuration..."
    cat > "$CONF_DIR/hostapd.conf" << HOSTAPD_EOF
interface=${iface}
driver=nl80211
ssid=${ssid}
hw_mode=g
channel=${channel}
ieee80211n=1
wmm_enabled=1
ht_capab=[SHORT-GI-20][SHORT-GI-40]
beacon_int=100
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_passphrase=${password}
wpa_pairwise=CCMP
rsn_pairwise=CCMP
max_num_sta=8
wpa_group_rekey=86400
ignore_broadcast_ssid=0
macaddr_acl=0
HOSTAPD_EOF

    log_info "Writing dnsmasq configuration..."
    cat > "$CONF_DIR/dnsmasq.conf" << DNSMASQ_EOF
interface=${iface}
bind-interfaces
dhcp-range=${subnet}.10,${subnet}.50,255.255.255.0,24h
dhcp-option=option:router,${subnet}.1
dhcp-option=option:dns-server,8.8.8.8,8.8.4.4
server=8.8.8.8
server=8.8.4.4
DNSMASQ_EOF

    log_ok "Hotspot configuration written to $CONF_DIR/"
}

install_hotspot_script() {
    local iface="$1"
    local subnet="$2"
    local country="$3"
    local upstream="$4"

    log_info "Installing hotspot management script..."
    cat > "$SCRIPT_PATH" << 'SCRIPT_EOF'
#!/bin/bash
# NEXTU 202N Mini WiFi Hotspot Manager
# Usage: sudo nextu-hotspot {start|stop|restart|status}

set -e

IFACE="__IFACE__"
HOSTAPD_BIN="/usr/sbin/hostapd"
CONF_DIR="/etc/nextu-hotspot"
HOSTAPD_CONF="$CONF_DIR/hostapd.conf"
DNSMASQ_CONF="$CONF_DIR/dnsmasq.conf"
HOSTAPD_PID="/var/run/nextu-hostapd.pid"
DNSMASQ_PID="/var/run/nextu-dnsmasq.pid"
SUBNET="__SUBNET__"
GATEWAY="${SUBNET}.1"
UPSTREAM="__UPSTREAM__"
COUNTRY="__COUNTRY__"

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: This script must be run as root (sudo)"
        exit 1
    fi
}

check_interface() {
    if ! ip link show "$IFACE" &>/dev/null; then
        echo "Error: Interface $IFACE not found. Is the NEXTU 202N plugged in?"
        exit 1
    fi
}

start_hotspot() {
    echo "=== Starting NEXTU 202N Hotspot ==="

    if [ -f "$HOSTAPD_PID" ] && kill -0 "$(cat "$HOSTAPD_PID")" 2>/dev/null; then
        echo "Hotspot is already running. Stop it first."
        exit 1
    fi

    check_interface

    # Set regulatory domain for channel availability
    iw reg set "$COUNTRY" 2>/dev/null || true
    sleep 1

    # Stop NetworkManager from managing this interface
    nmcli device set "$IFACE" managed no 2>/dev/null || true
    sleep 1

    # Configure the interface
    echo "[1/5] Configuring interface..."
    ip addr flush dev "$IFACE" 2>/dev/null || true
    ip link set "$IFACE" down 2>/dev/null || true
    ip addr add "${GATEWAY}/24" dev "$IFACE"
    ip link set "$IFACE" up
    sleep 1

    # Start hostapd
    echo "[2/5] Starting hostapd (AP mode)..."
    "$HOSTAPD_BIN" -B -P "$HOSTAPD_PID" "$HOSTAPD_CONF"
    sleep 2

    if ! [ -f "$HOSTAPD_PID" ] || ! kill -0 "$(cat "$HOSTAPD_PID")" 2>/dev/null; then
        echo "Error: hostapd failed to start"
        stop_hotspot
        exit 1
    fi
    echo "       AP is broadcasting SSID: $(grep '^ssid=' "$HOSTAPD_CONF" | cut -d= -f2)"

    # Start dnsmasq (DHCP + DNS)
    echo "[3/5] Starting DHCP server..."
    dnsmasq -C "$DNSMASQ_CONF" --pid-file="$DNSMASQ_PID"
    sleep 1

    # Enable IP forwarding
    echo "[4/5] Enabling IP forwarding..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    # Set up NAT
    echo "[5/5] Setting up NAT (internet sharing via $UPSTREAM)..."
    iptables -t nat -A POSTROUTING -o "$UPSTREAM" -j MASQUERADE
    iptables -A FORWARD -i "$IFACE" -o "$UPSTREAM" -j ACCEPT
    iptables -A FORWARD -i "$UPSTREAM" -o "$IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT

    echo ""
    echo "=== Hotspot is ACTIVE ==="
    echo "  SSID:      $(grep '^ssid=' "$HOSTAPD_CONF" | cut -d= -f2)"
    echo "  Password:  $(grep '^wpa_passphrase=' "$HOSTAPD_CONF" | cut -d= -f2)"
    echo "  Gateway:   $GATEWAY"
    echo "  DHCP:      ${SUBNET}.10 - ${SUBNET}.50"
    echo "  Internet:  shared via $UPSTREAM"
    echo ""
    echo "Stop with: sudo nextu-hotspot stop"
}

stop_hotspot() {
    echo "=== Stopping NEXTU 202N Hotspot ==="

    echo "[1/4] Removing NAT rules..."
    iptables -t nat -D POSTROUTING -o "$UPSTREAM" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i "$IFACE" -o "$UPSTREAM" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$UPSTREAM" -o "$IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

    echo "[2/4] Stopping DHCP server..."
    if [ -f "$DNSMASQ_PID" ]; then
        kill "$(cat "$DNSMASQ_PID")" 2>/dev/null || true
        rm -f "$DNSMASQ_PID"
    fi

    echo "[3/4] Stopping hostapd..."
    if [ -f "$HOSTAPD_PID" ]; then
        kill "$(cat "$HOSTAPD_PID")" 2>/dev/null || true
        rm -f "$HOSTAPD_PID"
    fi

    echo "[4/4] Resetting interface..."
    ip addr flush dev "$IFACE" 2>/dev/null || true
    ip link set "$IFACE" down 2>/dev/null || true
    nmcli device set "$IFACE" managed yes 2>/dev/null || true

    echo "=== Hotspot stopped ==="
}

show_status() {
    echo "=== NEXTU 202N Hotspot Status ==="
    echo ""

    if ip link show "$IFACE" &>/dev/null; then
        echo "Interface: $IFACE (FOUND)"
        echo "  MAC:   $(cat /sys/class/net/$IFACE/address 2>/dev/null || echo 'N/A')"
        echo "  State: $(cat /sys/class/net/$IFACE/operstate 2>/dev/null || echo 'N/A')"
        echo "  Mode:  $(iwconfig "$IFACE" 2>/dev/null | grep -oP 'Mode:\K\S+' || echo 'N/A')"
        echo "  IP:    $(ip -4 addr show "$IFACE" 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo 'none')"
    else
        echo "Interface: $IFACE (NOT FOUND)"
        return
    fi

    echo ""

    if [ -f "$HOSTAPD_PID" ] && kill -0 "$(cat "$HOSTAPD_PID")" 2>/dev/null; then
        echo "Hostapd:   RUNNING (PID $(cat "$HOSTAPD_PID"))"
        echo "  SSID:      $(grep '^ssid=' "$HOSTAPD_CONF" | cut -d= -f2)"
        echo "  Channel:   $(grep '^channel=' "$HOSTAPD_CONF" | cut -d= -f2)"
    else
        echo "Hostapd:   STOPPED"
    fi

    if [ -f "$DNSMASQ_PID" ] && kill -0 "$(cat "$DNSMASQ_PID")" 2>/dev/null; then
        echo "DHCP:      RUNNING (PID $(cat "$DNSMASQ_PID"))"
    else
        echo "DHCP:      STOPPED"
    fi

    if iptables -t nat -C POSTROUTING -o "$UPSTREAM" -j MASQUERADE 2>/dev/null; then
        echo "NAT:       ACTIVE (via $UPSTREAM)"
    else
        echo "NAT:       INACTIVE"
    fi

    echo ""
    echo "Connected clients:"
    if [ -f /var/lib/misc/dnsmasq.leases ]; then
        if [ -s /var/lib/misc/dnsmasq.leases ]; then
            cat /var/lib/misc/dnsmasq.leases | awk '{printf "  %-16s %-18s %s\n", $3, $2, $4}'
        else
            echo "  (none)"
        fi
    else
        echo "  (none)"
    fi
}

check_root

case "${1:-}" in
    start)   start_hotspot ;;
    stop)    stop_hotspot ;;
    status)  show_status ;;
    restart) stop_hotspot; sleep 2; start_hotspot ;;
    *)
        echo "NEXTU 202N Mini WiFi Hotspot Manager"
        echo ""
        echo "Usage: sudo nextu-hotspot {start|stop|restart|status}"
        echo ""
        echo "Commands:"
        echo "  start    - Start the WiFi hotspot"
        echo "  stop     - Stop the WiFi hotspot"
        echo "  restart  - Restart the WiFi hotspot"
        echo "  status   - Show hotspot status and connected clients"
        echo ""
        echo "Configuration: $CONF_DIR/"
        exit 1
        ;;
esac
SCRIPT_EOF

    # Replace placeholders with actual values
    sed -i "s|__IFACE__|${iface}|g" "$SCRIPT_PATH"
    sed -i "s|__SUBNET__|${subnet}|g" "$SCRIPT_PATH"
    sed -i "s|__UPSTREAM__|${upstream}|g" "$SCRIPT_PATH"
    sed -i "s|__COUNTRY__|${country}|g" "$SCRIPT_PATH"

    chmod +x "$SCRIPT_PATH"
    log_ok "Hotspot script installed at $SCRIPT_PATH"
}

# ─── Interactive Configuration ───────────────────────────────────────────────

interactive_configure() {
    local iface=$(detect_interface)
    local upstream=$(get_upstream_interface)

    echo ""
    echo "=== NEXTU 202N Hotspot Configuration ==="
    echo ""

    # Interface
    if [ -n "$iface" ]; then
        echo "Detected WiFi interface: $iface"
    else
        iface="wlx00ada70263bc"
        echo "Could not detect interface, using default: $iface"
    fi
    read -rp "WiFi interface [$iface]: " input
    iface="${input:-$iface}"

    # Upstream
    if [ -n "$upstream" ]; then
        echo "Detected upstream interface: $upstream"
    else
        upstream="enp1s0"
    fi
    read -rp "Internet interface [$upstream]: " input
    upstream="${input:-$upstream}"

    # SSID
    read -rp "Hotspot SSID [$DEFAULT_SSID]: " input
    local ssid="${input:-$DEFAULT_SSID}"

    # Password
    read -rp "Hotspot password [$DEFAULT_PASSWORD]: " input
    local password="${input:-$DEFAULT_PASSWORD}"
    if [ "${#password}" -lt 8 ]; then
        log_error "Password must be at least 8 characters"
        exit 1
    fi

    # Channel
    read -rp "WiFi channel (1-11) [$DEFAULT_CHANNEL]: " input
    local channel="${input:-$DEFAULT_CHANNEL}"

    # Country
    read -rp "Country code (US/KR/GB/JP/...) [$DEFAULT_COUNTRY]: " input
    local country="${input:-$DEFAULT_COUNTRY}"

    local subnet="$DEFAULT_SUBNET"

    echo ""
    echo "Configuration:"
    echo "  Interface:  $iface"
    echo "  Upstream:   $upstream"
    echo "  SSID:       $ssid"
    echo "  Password:   $password"
    echo "  Channel:    $channel"
    echo "  Country:    $country"
    echo "  Subnet:     ${subnet}.0/24"
    echo ""

    read -rp "Proceed? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        echo "Cancelled."
        exit 0
    fi

    install_hotspot_configs "$iface" "$ssid" "$password" "$channel" "$subnet" "$country" "$upstream"
    install_hotspot_script "$iface" "$subnet" "$country" "$upstream"

    echo ""
    log_ok "Configuration complete!"
    echo ""
    echo "Start the hotspot with: sudo nextu-hotspot start"
}

# ─── Main Commands ──────────────────────────────────────────────────────────

do_install() {
    echo "============================================="
    echo "  NEXTU 202N Mini WiFi Hotspot Installer v${VERSION}"
    echo "============================================="
    echo ""

    check_ubuntu
    check_adapter

    # Phase 1: Install dependencies
    echo ""
    echo "--- Phase 1: Dependencies ---"
    install_dependencies

    # Phase 2: Build and install driver
    echo ""
    echo "--- Phase 2: Driver Installation ---"
    local srcdir=$(clone_driver)
    apply_patches "$srcdir"
    install_driver_dkms "$srcdir"
    blacklist_old_driver
    load_new_driver

    # Phase 3: Configure hotspot
    echo ""
    echo "--- Phase 3: Hotspot Configuration ---"
    interactive_configure

    # Cleanup
    rm -rf /tmp/rtl8188eus-build

    echo ""
    echo "============================================="
    echo "  Installation Complete!"
    echo "============================================="
    echo ""
    echo "  Usage:"
    echo "    sudo nextu-hotspot start   - Start hotspot"
    echo "    sudo nextu-hotspot stop    - Stop hotspot"
    echo "    sudo nextu-hotspot status  - Show status"
    echo ""
    echo "  Config: $CONF_DIR/"
    echo "  Report: See nextu-hotspot-report.md"
    echo "============================================="
}

do_uninstall() {
    echo "=== Uninstalling NEXTU 202N Hotspot ==="
    echo ""

    # Stop hotspot if running
    if [ -f /var/run/nextu-hostapd.pid ]; then
        "$SCRIPT_PATH" stop 2>/dev/null || true
    fi

    # Remove DKMS driver
    log_info "Removing DKMS driver..."
    dkms remove -m "$DRIVER_NAME" -v "$DRIVER_VERSION" --all 2>/dev/null || true
    rm -rf "/usr/src/${DRIVER_NAME}-${DRIVER_VERSION}"

    # Remove blacklist
    rm -f "$BLACKLIST_FILE"

    # Remove configs and script
    rm -rf "$CONF_DIR"
    rm -f "$SCRIPT_PATH"

    # Reload original driver
    rmmod 8188eu 2>/dev/null || true
    modprobe rtl8xxxu 2>/dev/null || true

    log_ok "Uninstallation complete. Original rtl8xxxu driver restored."
}

# ─── Entry Point ─────────────────────────────────────────────────────────────

check_root

case "${1:-}" in
    install)
        do_install
        ;;
    uninstall|remove)
        do_uninstall
        ;;
    configure|config)
        interactive_configure
        ;;
    --version|-v)
        echo "NEXTU 202N Hotspot Installer v${VERSION}"
        ;;
    *)
        echo "NEXTU 202N Mini WiFi Hotspot Installer v${VERSION}"
        echo ""
        echo "Usage: sudo $0 {install|uninstall|configure}"
        echo ""
        echo "Commands:"
        echo "  install     - Full installation (driver + hotspot)"
        echo "  uninstall   - Remove driver and configuration"
        echo "  configure   - Reconfigure hotspot settings"
        echo ""
        echo "After installation:"
        echo "  sudo nextu-hotspot start    - Start hotspot"
        echo "  sudo nextu-hotspot stop     - Stop hotspot"
        echo "  sudo nextu-hotspot status   - Show status"
        exit 1
        ;;
esac
