# NEXTU 202N Mini WiFi Hotspot Setup Report

## Executive Summary

This document details the complete process of enabling WiFi hotspot (AP) mode on a
NEXTU 202N Mini USB WiFi adapter (Realtek RTL8188EUS chipset) running Ubuntu with
kernel 6.17. The default kernel driver (`rtl8xxxu`) does not support AP mode. We
successfully built and installed the `aircrack-ng/rtl8188eus` out-of-tree driver
with custom kernel 6.17 compatibility patches to enable full AP mode support.

---

## 1. Hardware Identification

| Property | Value |
|----------|-------|
| Product | NEXTU 202N Mini WiFi |
| Chipset | Realtek RTL8188EUS |
| USB ID | `0bda:8179` |
| Interface | `wlx00ada70263bc` |
| Band | 2.4 GHz (802.11b/g/n) |
| Antenna | 1T1R (single stream) |

### Detection Command

```bash
lsusb | grep 0bda:8179
# Output: Bus 001 Device 030: ID 0bda:8179 Realtek Semiconductor Corp. RTL8188EUS 802.11n Wireless Network Adapter
```

---

## 2. Problem Analysis

### 2.1 Default Kernel Driver: `rtl8xxxu`

The Linux kernel ships with the `rtl8xxxu` driver for RTL8188EUS devices. This driver
integrates with the nl80211/cfg80211 wireless subsystem but has a critical limitation:

```
Supported interface modes:
    * managed
    * monitor
```

**AP mode is NOT supported.** Attempting to start hostapd returns:

```
nl80211: Set mode ifindex 5 iftype 3 (AP)
nl80211: Failed to set interface 5 to mode 3: -95 (Operation not supported)
```

NetworkManager also rejects hotspot creation:

```
Error: Device 'wlx00ada70263bc' supports neither AP nor Ad-Hoc mode.
```

### 2.2 Available Alternative Drivers

| Driver | Source | AP Support | nl80211 | Kernel 6.17 |
|--------|--------|-----------|---------|-------------|
| `rtl8xxxu` | In-kernel | No | Yes | Yes |
| `8188eu` (lwfinger) | github.com/lwfinger/rtl8188eu | Partial (wext) | No | Needs patches |
| `8188eu` (aircrack-ng) | github.com/aircrack-ng/rtl8188eus | **Yes** | **Yes** | **Needs patches** |

The **aircrack-ng/rtl8188eus** driver was selected because it provides full AP mode
support via the standard nl80211/cfg80211 interface.

---

## 3. Kernel 6.17 Compatibility Patches

The aircrack-ng driver was written for older kernels. Four categories of changes
were needed to compile on kernel 6.17.

### 3.1 Build System: `EXTRA_CFLAGS` to `ccflags-y`

**Problem**: Kernel 6.4+ removed support for `EXTRA_CFLAGS` in out-of-tree module
Makefiles. The variable is silently ignored, causing all `-I` include paths to be
missing from the gcc command line.

**Symptom**:
```
core/rtw_cmd.c:17:10: fatal error: drv_types.h: No such file or directory
```

**Fix**: Replace all `EXTRA_CFLAGS +=` with `ccflags-y +=` and `EXTRA_LDFLAGS +=`
with `ldflags-y +=` in the Makefile.

```bash
sed -i 's/^EXTRA_CFLAGS += /ccflags-y += /g; s/^EXTRA_LDFLAGS += /ldflags-y += /g' Makefile
```

Also remove broken `$(srctree)/$(src)/` include paths (in kernel 6.4+, `$(srctree)`
is an absolute path, making `$(srctree)/$(src)` produce double absolute paths):

```bash
sed -i 's|-I$(srctree)/$(src)/include||g' Makefile
sed -i 's|-I$(srctree)/$(src)/platform||g' Makefile
sed -i 's|-I$(srctree)/$(src)/hal/btc||g' Makefile
sed -i 's|-I$(srctree)/$(src)/hal/phydm||g' Makefile
```

### 3.2 Timer API: `from_timer` to `timer_container_of`

**Problem**: The `from_timer()` macro was renamed to `timer_container_of()` in
kernel 6.17. Both have identical signatures.

**Symptom**:
```
error: implicit declaration of function 'from_timer'; did you mean 'mod_timer'?
```

**Fix**:
```bash
sed -i 's/from_timer/timer_container_of/g' include/osdep_service_linux.h
```

Note: Only replace in header files. Some `.c` files use `from_timer` as a
parameter name (e.g., `u8 from_timer`) — those must NOT be changed.

### 3.3 Timer API: `del_timer_sync` to `timer_delete_sync`

**Problem**: `del_timer_sync()` was removed in kernel 6.2, replaced by
`timer_delete_sync()`.

**Symptom**:
```
error: implicit declaration of function 'del_timer_sync'; did you mean 'dev_mc_sync'?
```

**Fix**:
```bash
sed -i 's/del_timer_sync/timer_delete_sync/g' include/osdep_service_linux.h
```

### 3.4 cfg80211 API: MLO (Multi-Link Operation) Parameters

**Problem**: Kernel 6.17 added MLO support to cfg80211, changing several function
signatures by adding `radio_idx` and `link_id` parameters.

**Symptom**:
```
error: initialization of 'int (*)(struct wiphy *, int, u32)' from incompatible
pointer type 'int (*)(struct wiphy *, u32)' [-Werror=incompatible-pointer-types]
```

**Affected functions and fixes** (in `os_dep/linux/ioctl_cfg80211.c`):

| Function | Old Signature | New Parameter |
|----------|--------------|---------------|
| `cfg80211_rtw_set_wiphy_params` | `(wiphy, u32)` | Add `int radio_idx` |
| `cfg80211_rtw_set_txpower` | `(wiphy, wdev, enum, int)` | Add `int radio_idx` |
| `cfg80211_rtw_get_txpower` | `(wiphy, wdev, int*)` | Add `int radio_idx, unsigned int link_id` |
| `cfg80211_rtw_set_monitor_channel` | `(wiphy, chandef*)` | Add `struct net_device *dev` |

---

## 4. Build and Installation Process

### 4.1 Prerequisites

```bash
sudo apt-get install -y build-essential dkms git iw hostapd linux-headers-$(uname -r)
```

### 4.2 Clone Driver Source

```bash
cd /tmp
git clone https://github.com/aircrack-ng/rtl8188eus.git
```

### 4.3 Apply Patches

All patches from Section 3 are applied to the source tree.

### 4.4 DKMS Build and Install

```bash
sudo cp -r /tmp/rtl8188eus /usr/src/realtek-rtl8188eus-5.3.9~20221105
sudo dkms add -m realtek-rtl8188eus -v 5.3.9~20221105
sudo dkms build -m realtek-rtl8188eus -v 5.3.9~20221105
sudo dkms install -m realtek-rtl8188eus -v 5.3.9~20221105
```

### 4.5 Blacklist Old Driver

```bash
echo "blacklist rtl8xxxu" | sudo tee /etc/modprobe.d/blacklist-rtl8xxxu.conf
```

### 4.6 Load New Driver

```bash
sudo rmmod rtl8xxxu 2>/dev/null
sudo modprobe 8188eu
```

### 4.7 Verify AP Support

```bash
iw phy | grep -A 10 "Supported interface modes"
# Should show:
#   * managed
#   * AP         <-- This is what we need
#   * monitor
#   * P2P-client
#   * P2P-GO
```

---

## 5. Hotspot Configuration

### 5.1 hostapd Configuration (`/etc/nextu-hotspot/hostapd.conf`)

```ini
interface=wlx00ada70263bc
driver=nl80211
ssid=NEXTU-Hotspot
hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=1
ht_capab=[SHORT-GI-20][SHORT-GI-40]
beacon_int=100
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_passphrase=nextu2024
wpa_pairwise=CCMP
rsn_pairwise=CCMP
max_num_sta=8
wpa_group_rekey=86400
ignore_broadcast_ssid=0
macaddr_acl=0
```

### 5.2 dnsmasq Configuration (`/etc/nextu-hotspot/dnsmasq.conf`)

```ini
interface=wlx00ada70263bc
bind-interfaces
dhcp-range=192.168.50.10,192.168.50.50,255.255.255.0,24h
dhcp-option=option:router,192.168.50.1
dhcp-option=option:dns-server,8.8.8.8,8.8.4.4
server=8.8.8.8
server=8.8.4.4
```

### 5.3 Regulatory Domain

The wireless regulatory domain must be set for channels to be available in AP mode:

```bash
sudo iw reg set US
```

Without this, hostapd reports `Channel X not allowed for AP mode, flags: 0x0`.

---

## 6. Hotspot Management

The `nextu-hotspot` script (`/usr/local/bin/nextu-hotspot`) manages the full
hotspot lifecycle:

```bash
sudo nextu-hotspot start     # Start hotspot
sudo nextu-hotspot stop      # Stop hotspot
sudo nextu-hotspot restart   # Restart hotspot
sudo nextu-hotspot status    # Show status and connected clients
```

### Start Sequence

1. Disable NetworkManager control of the WiFi interface
2. Set regulatory domain
3. Configure IP address (192.168.50.1/24)
4. Start hostapd (AP mode)
5. Start dnsmasq (DHCP + DNS)
6. Enable IP forwarding (`net.ipv4.ip_forward=1`)
7. Configure iptables NAT (masquerade via upstream interface)

### Stop Sequence

1. Remove iptables NAT rules
2. Stop dnsmasq
3. Stop hostapd
4. Reset interface and return to NetworkManager

---

## 7. Approaches Attempted and Rejected

### 7.1 Standard hostapd with `rtl8xxxu` (nl80211)

Failed immediately — driver returns `-EOPNOTSUPP` when setting interface to AP mode.

### 7.2 nmcli WiFi Hotspot

```bash
nmcli device wifi hotspot ifname wlx00ada70263bc ssid "Test" password "password"
```

Failed with `rtl8xxxu` (no AP support) and with lwfinger `8188eu` (fell back to
WEP because driver uses wext, not nl80211).

### 7.3 lwfinger/rtl8188eu Driver

This driver supports AP mode via wext (master mode), but:
- Uses the proprietary `rtl871xdrv` hostapd driver (not in standard hostapd)
- The custom hostapd from the repo was compiled against `libssl.so.1.1` (unavailable)
- Building the custom hostapd worked, but the driver doesn't properly set AP-mode
  channel flags on kernel 6.17, causing `Channel X not allowed for AP mode`
- The `RTL_IOCTL_HOSTAPD` ioctl returns "Operation not supported"

### 7.4 aircrack-ng/rtl8188eus Driver (Selected)

This driver provides full AP mode support via the standard nl80211/cfg80211 interface.
Required 4 categories of kernel 6.17 patches (detailed in Section 3). After patching,
works perfectly with the standard system hostapd.

---

## 8. Files Installed

| Path | Purpose |
|------|---------|
| `/usr/src/realtek-rtl8188eus-5.3.9~20221105/` | DKMS driver source |
| `/lib/modules/$(uname -r)/updates/dkms/8188eu.ko.zst` | Compiled driver module |
| `/etc/modprobe.d/blacklist-rtl8xxxu.conf` | Blacklist old driver |
| `/etc/nextu-hotspot/hostapd.conf` | Hotspot AP configuration |
| `/etc/nextu-hotspot/dnsmasq.conf` | DHCP/DNS configuration |
| `/usr/local/bin/nextu-hotspot` | Hotspot management script |

---

## 9. Troubleshooting

### Adapter not detected
```bash
lsusb | grep 0bda:8179
# If missing, replug the USB adapter
```

### Driver not loaded
```bash
lsmod | grep 8188eu
# If missing:
sudo modprobe 8188eu
```

### Channels not available
```bash
sudo iw reg set US   # or your country code (KR, JP, GB, etc.)
```

### Hotspot won't start after reboot
```bash
# The regulatory domain resets on reboot. The nextu-hotspot script
# handles this automatically, but you can also persist it:
echo 'REGDOMAIN=US' | sudo tee /etc/default/crda
```

### Driver doesn't survive kernel update
DKMS should automatically rebuild for new kernels. If not:
```bash
sudo dkms build -m realtek-rtl8188eus -v 5.3.9~20221105
sudo dkms install -m realtek-rtl8188eus -v 5.3.9~20221105
```

---

## 10. Security Considerations

- WPA2-PSK with CCMP/AES encryption (recommended minimum)
- Change the default password (`nextu2024`) before production use
- Consider WPA3-SAE if all clients support it
- The hotspot shares the host's internet — firewall rules recommended for production
- Max 8 simultaneous clients (configurable via `max_num_sta`)

---

*Report generated: 2026-02-27*
*System: Ubuntu 24.04, Kernel 6.17.0-14-generic, x86_64*
