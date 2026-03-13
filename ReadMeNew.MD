# BirdDog

Field-deployable RF video mesh appliance on Raspberry Pi 3B. Self-forming Wi-Fi mesh backbone with edge camera encoding and live WebRTC streaming to a central dashboard.

---

## Hardware

| Node | Role | Adapters |
|------|------|----------|
| BDM (Base Data Master) | Mesh node + AP + MediaMTX server + dashboard | Comfast CF-WU782AC (mesh) + Edimax EW-7811Un (AP) |
| BDC (Base Data Client) | Mesh node + camera encoder | Comfast CF-WU782AC (mesh) + Pi ribbon camera |

All nodes run Pi 3B, 64-bit Pi OS (aarch64). Management is always over `eth0` (SSH). Onboard WiFi (`wlan0`) is intentionally blocked to reduce RF congestion.

### Radio layout (baked into golden image via udev)

| Interface | Adapter | Driver | Role |
|-----------|---------|--------|------|
| wlan0 | Onboard BCM | brcmfmac | Blocked — not used |
| wlan1 | Comfast CF-WU782AC | mt76x2u | Mesh backbone (all nodes) |
| wlan2 | Edimax EW-7811Un | rtl8192cu | AP + DHCP (BDM only) |

---

## Network layout

| Network | Subnet | Purpose |
|---------|--------|---------|
| Mesh | 10.10.20.0/24 | Inter-node backbone (wlan1) |
| AP | 10.10.10.0/24 | Operator WiFi access (BDM wlan2) |

Mesh IP assignment: `10.10.20.(node_number × 10)` — e.g. node 01 → `10.10.20.10`

BDM AP: `10.10.10.1` — dashboard reachable at `http://10.10.10.1` or `http://bdm-01.local`

---

## Quickstart

### Step 1 — Build the golden master image

Flash a fresh **64-bit Pi OS** (aarch64) SD card. Boot with `eth0` connected and both USB WiFi adapters plugged in. Then run the bootstrap one-liner:

```bash
rm -f ~/golden_image_creation.sh && \
curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/common/golden_image_creation.sh?$(date +%s)" \
  -o ~/golden_image_creation.sh && \
chmod +x ~/golden_image_creation.sh && \
sudo bash ~/golden_image_creation.sh && \
rm -f ~/golden_image_creation.sh
```

Select **[F] Full install** when prompted. This installs all packages, downloads the MediaMTX binary, bakes in udev radio naming rules, and installs the `birddog` CLI.

**Power off. Clone this SD card. This is your golden master image.**

---

### Step 2 — Deploy a node from the golden master

Flash a clone to a new SD card. Boot with `eth0` connected, then:

```bash
# Pull latest scripts (fast — no apt, no binary download)
birddog install        # choose [R] Refresh

# Reboot so udev radio naming takes effect
sudo reboot

# After reboot — confirm radio layout before configuring
birddog radios

# Assign role and configure the node
birddog configure
```

`birddog configure` will prompt for role (BDM or BDC) and node number, then install and start all role-specific services.

---

## CLI reference

```
birddog install      Full package + script install, or script refresh only
birddog update       Fetch latest scripts from repo (safe on live nodes)
birddog configure    Assign role (BDM / BDC), install services
birddog reset        Wipe node config, return to unconfigured state
birddog verify       Full node health check
birddog status       Platform version + commit state vs remote
birddog radios       Show current radio layout (driver, mode, state)
birddog restart      Restart all BirdDog services
```

---

## Repo structure

```
common/
  golden_image_creation.sh   Full install or script refresh
  script_update.sh           Script-only update (no apt, no binary)
  device_configure.sh        Role assignment and service installation
  oobe_reset.sh              Wipe config, return node to unconfigured state
  verify_node.sh             Node health check

bdm/
  bdm_AP_setup.sh            hostapd + dnsmasq AP on wlan2
  bdm_mediamtx_setup.sh      MediaMTX RTSP/WebRTC server
  bdm_web_setup.sh           nginx + live quad-view dashboard

bdc/
  bdc_fresh_install_setup.sh rpicam-vid + ffmpeg stream to BDM

mesh/
  add_mesh_network.sh        802.11s mesh service (all nodes)

button/
  button_push.sh             GPIO button handler (stub)

buzzer/
  buzzer_test.sh             Buzzer test (stub)
```

---

## Services

| Service | Nodes | Purpose |
|---------|-------|---------|
| `birddog-mesh` | All | 802.11s mesh on wlan1, state machine, peer monitoring |
| `birddog-stream` | BDC | rpicam-vid → ffmpeg → RTSP push to BDM |
| `mediamtx` | BDM | RTSP ingest + WebRTC restream |
| `hostapd` | BDM | AP on wlan2 (SSID: BirdDog) |
| `dnsmasq` | BDM | DHCP for AP clients |
| `nginx` | BDM | Serves dashboard on port 80 |
| `birddog-block-onboard-wifi` | All | Blocks wlan0 at boot |

---

## Dashboard

The BDM serves a live quad-view WebRTC dashboard at `http://10.10.10.1` (or `http://bdm-01.local` over the mesh).

Streams are expected on MediaMTX paths `cam01` through `cam04`. Tiles show a live indicator dot (green = streaming, red = no signal) and auto-refresh every 15 seconds.

Stream URLs directly:
```
http://<bdm-ip>:8889/cam01
http://<bdm-ip>:8889/cam02
...
```

---

## Useful diagnostics

```bash
# Node health
birddog verify
birddog status
birddog radios

# Service logs
journalctl -u birddog-mesh -f
journalctl -u birddog-stream -f
journalctl -u mediamtx -f
journalctl -u hostapd -f

# Mesh peers
iw dev wlan1 station dump

# Active streams
curl -s http://localhost:9997/v3/paths/list

# Camera test (BDC)
rpicam-vid -t 5000 -o /tmp/test.h264

# mDNS
ping bdm-01.local
ping bdc-01.local

# Clear SSH known hosts after reflash
ssh-keygen -R <ip>
```

---

## Version identity

Each node tracks its installed state in `/opt/birddog/version/`:

```
COMMIT    short git SHA of last successful install/update
VERSION   human-readable label (commit-<sha>)
BUILD     UTC timestamp of last install/update
```

`birddog status` shows local commit vs remote and flags if an update is available.
