# NEXTU 202N Mini WiFi Hotspot

Turn your **NEXTU 202N Mini USB WiFi adapter** (Realtek RTL8188EUS) into a fully functional WiFi hotspot on Ubuntu.

## The Problem

The default Linux kernel driver (`rtl8xxxu`) for the RTL8188EUS chipset **does not support AP (Access Point) mode**, making it impossible to create a WiFi hotspot out of the box.

## The Solution

This project provides:

1. **An automated installer** that builds and installs the [aircrack-ng/rtl8188eus](https://github.com/aircrack-ng/rtl8188eus) out-of-tree driver with full AP mode support, including kernel compatibility patches for Ubuntu kernels up to 6.17+
2. **A hotspot management script** (`nextu-hotspot`) for easy start/stop/status control
3. **A detailed technical report** documenting the entire process, patches, and troubleshooting

## Quick Start

```bash
# Download and run the installer
chmod +x nextu-hotspot-installer.sh
sudo ./nextu-hotspot-installer.sh install

# Start the hotspot
sudo nextu-hotspot start

# Check status
sudo nextu-hotspot status

# Stop the hotspot
sudo nextu-hotspot stop
```

## Requirements

- **OS**: Ubuntu 22.04+ (or Debian-based)
- **Kernel**: 5.15 - 6.17+ (patches applied automatically)
- **Hardware**: NEXTU 202N Mini WiFi USB adapter (Realtek RTL8188EUS, USB ID `0bda:8179`)
- **Internet**: Wired ethernet connection for internet sharing

## What the Installer Does

1. Installs build dependencies (`build-essential`, `dkms`, `git`, `iw`, `hostapd`, kernel headers)
2. Clones the aircrack-ng RTL8188EUS driver source
3. Applies kernel-version-specific patches:
   - `EXTRA_CFLAGS` to `ccflags-y` (kernel 6.4+)
   - `from_timer` to `timer_container_of` (kernel 6.16+)
   - `del_timer_sync` to `timer_delete_sync` (kernel 6.2+)
   - cfg80211 MLO parameter additions (kernel 6.17+)
4. Builds and installs the driver via DKMS (survives kernel updates)
5. Blacklists the old `rtl8xxxu` driver
6. Interactively configures the hotspot (SSID, password, channel, country)
7. Installs the `nextu-hotspot` management script

## Hotspot Management

```bash
sudo nextu-hotspot start     # Start the WiFi hotspot
sudo nextu-hotspot stop      # Stop the WiFi hotspot
sudo nextu-hotspot restart   # Restart the hotspot
sudo nextu-hotspot status    # Show status and connected clients
```

### Default Configuration

| Setting | Value | Config File |
|---------|-------|-------------|
| SSID | NEXTU-Hotspot | `/etc/nextu-hotspot/hostapd.conf` |
| Password | nextu2024 | `/etc/nextu-hotspot/hostapd.conf` |
| Channel | 6 (2.4 GHz) | `/etc/nextu-hotspot/hostapd.conf` |
| Gateway | 192.168.50.1 | `/etc/nextu-hotspot/dnsmasq.conf` |
| DHCP Range | .10 - .50 | `/etc/nextu-hotspot/dnsmasq.conf` |
| Encryption | WPA2-PSK/CCMP | `/etc/nextu-hotspot/hostapd.conf` |

Edit the config files and run `sudo nextu-hotspot restart` to apply changes.

## Uninstall

```bash
sudo ./nextu-hotspot-installer.sh uninstall
```

This removes the driver, configs, and restores the original `rtl8xxxu` driver.

## Files

| File | Description |
|------|-------------|
| `nextu-hotspot-installer.sh` | Automated installer/uninstaller |
| `nextu-hotspot-report.md` | Detailed technical report and documentation |

## Tested On

- Ubuntu 24.04 LTS, Kernel 6.17.0-14-generic, x86_64
- NEXTU 202N Mini (USB `0bda:8179`, Realtek RTL8188EUS)

## Disclaimer

NEXTU is a trademark of its respective owner. This project is not affiliated with or endorsed by NEXTU. It provides open-source driver tooling for the Realtek RTL8188EUS chipset.

## License

MIT
