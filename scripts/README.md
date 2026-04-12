# ODROID-HC4 Automated Setup Scripts

Automated installation scripts for setting up an ODROID-HC4 media center with Jellyfin, Sonarr, Radarr, Prowlarr, Transmission, Byparr, and OpenMediaVault.

## Quick Start

### 1. Prerequisites

Before running these scripts:
- DietPi must already be installed and accessible via SSH
- You should be logged in as root or have sudo access
- The HC4 should have internet connectivity

### 2. Download the Scripts

Download and extract the setup scripts:

```bash
curl -L https://github.com/SylvainRX/ODROID-HC4-Media-Center-Setup/archive/refs/heads/main.tar.gz | tar xz
cd ODROID-HC4-Media-Center-Setup-main/scripts
```

### 3. Configure

Edit `config.sh` and fill in your values:

```bash
nano config.sh
```

**Recommended:**
- `NORDVPN_TOKEN`: Generate at https://my.nordaccount.com/dashboard/nordvpn/  
  *Leave empty to skip NordVPN setup*

**Optional (have sensible defaults):**
- `DATA_DRIVE`: OMV mount path (e.g., `/srv/dev-disk-by-uuid-XXXX`).  
  *Leave empty — step 03 will scan `/srv/` and present an interactive menu to select your drive.*
- `TZ`: Your timezone (default: `Canada/Eastern`)
- `PUID`/`PGID`: Docker user IDs (default: `1000`)
- `FAN_MIN_TEMP`/`FAN_MAX_TEMP`: Fan control thresholds

### 4. Run

```bash
sudo ./setup.sh
```

The script will:
1. Configure fan control
2. Install OpenMediaVault and **pause for manual web UI setup**
3. Interactively select your media drive and create the `/media` symlink
4. Install and configure NordVPN (if token provided, otherwise skipped)
5. Install Docker and Docker Compose
6. Deploy all 6 containers via docker-compose (Transmission, Prowlarr, Sonarr, Radarr, Jellyfin, Byparr)
7. Wire services together via REST APIs (including Byparr proxy registration)

---

## What Gets Automated

| Component | What's Automated | What's Manual |
|-----------|-----------------|---------------|
| **Fan Control** | ✅ Fully automated | None |
| **OpenMediaVault** | ✅ Installation | RAID/SMB/user setup via web UI |
| **Drive Setup** | ✅ Interactive drive selection, `/media` symlink creation | None (interactive prompt) |
| **NordVPN** | ✅ Install, login, subnet detection, P2P connection, autoconnect, DNS config | Generate access token (one-time), or skip entirely |
| **Docker** | ✅ Install Docker Engine, Compose plugin, DNS config, apparmor workaround | None |
| **Containers** | ✅ All 6 containers deployed (Transmission, Prowlarr, Sonarr, Radarr, Jellyfin, Byparr) | None |
| **Service Wiring** | ✅ Prowlarr↔Sonarr/Radarr, Prowlarr↔Byparr proxy, Transmission setup, hardlinks enabled | Add indexers in Prowlarr web UI |
| **Jellyfin** | ✅ Container deployed | Create admin account on first visit |

---

## Step-by-Step Breakdown

### Step 01: Fan Control
- Installs `fancontrol` package
- Writes `/etc/fancontrol` with hardware-specific config
- Enables and starts the service

**Duration:** ~30 seconds  
**User input:** None

---

### Step 02: OpenMediaVault

**Automated:**
- Downloads and installs OMV (takes 15-45 minutes)
- Installs OMV RAID plugin

**Manual (web UI):**
1. Go to `http://<HC4-IP>`
2. Login: `admin` / `openmediavault`
3. Set up RAID (if using multiple drives): `Storage > Software RAID`
4. Mount file systems: `Storage > File Systems`
5. Create shared folders: `Storage > Shared Folders`
6. Enable SMB/CIFS and create shares: `Services > SMB/CIFS`
7. Create users: `Users > Users`

Then press Enter to continue — step 03 will handle drive selection automatically.

**Duration:** 20-50 minutes total (mostly automated install time)

---

### Step 03: Set Data Drive

Scans `/srv/dev-disk-*` for drives mounted by OMV and presents an interactive selection menu. The selected drive is symlinked to `/media`, which all containers use as their storage root.

If `DATA_DRIVE` is pre-set in `config.sh`, the interactive menu is skipped and that path is used directly.

**Menu format:**
```
1) /srv/dev-disk-by-uuid-abc123  [ext4, 1.8T total, 800G free]
2) /srv/dev-disk-by-uuid-def456  [xfs, 3.6T total, 3.1T free]
3) Quit
Select your media drive:
```

**Duration:** <1 minute  
**User input:** Drive selection (unless `DATA_DRIVE` is pre-set)

---

### Step 04: NordVPN
- Downloads and runs NordVPN installer
- Logs in with your access token
- Auto-detects local subnet and whitelists it (preserves SSH access)
- Connects to P2P server
- Configures autoconnect on boot
- Configures systemd-resolved DNS fallback for Docker/system resolution

**Duration:** 1-2 minutes  
**User input:** Token must be in `config.sh` (or step is skipped entirely)

---

### Step 05: Docker
- Installs apparmor packages (workaround for generic errors)
- Installs Docker Engine via `get.docker.com`
- Installs Docker Compose plugin
- Configures Docker daemon DNS for container registry access
- Enables Docker service

**Duration:** 2-3 minutes  
**User input:** None

---

### Step 06: Deploy Containers
- Creates all required directories:
   - `/home/dietpi/Docker/{Transmission,Prowlarr,Sonarr,Radarr,Jellyfin}`
   - `/media/torrents`
   - `/media/media/{tv,movies}`
   - Note: Byparr is stateless; no config directory needed
- Generates `docker-compose.yml` from template (substitutes `TZ`, `PUID`, etc.)
- Runs `docker compose up -d`
- Verifies all 6 containers are running

**Duration:** 2-3 minutes (container image downloads)  
**User input:** None

---

### Step 07: Wire Services via API

**Automated API calls:**
- Reads API keys from each service's `config.xml` on disk
- Adds Sonarr and Radarr as applications in Prowlarr
- Adds Transmission as download client in Sonarr and Radarr
- Enables hardlinks in Sonarr and Radarr
- Adds root folders (`/tv`, `/movies`)
- Registers Byparr as FlareSolverr-compatible indexer proxy in Prowlarr

**Result:** Once you add indexers in Prowlarr's web UI, they automatically sync to Sonarr and Radarr. Cloudflare-protected indexers automatically use Byparr. Downloads via Transmission are automatically configured.

**Duration:** 1-2 minutes  
**User input:** None

---

## Command Reference

### Basic Usage
```bash
sudo ./setup.sh                # Run full setup
sudo ./setup.sh --dry-run      # Preview without making changes
sudo ./setup.sh --status       # Show which steps are completed
```

### Advanced Usage
```bash
sudo ./setup.sh --from 03      # Re-run drive selection (step 03 onward)
sudo ./setup.sh --reset        # Reset all steps (start fresh)
sudo ./setup.sh --reset 03     # Reset only step 03
```

### Resuming After Interruption
If the script stops (network issue, power loss, etc.), just re-run:
```bash
sudo ./setup.sh
```
Completed steps are automatically skipped.

---

## Post-Setup Manual Steps

After the automated setup completes:

1. **Add indexers in Prowlarr:** `http://<HC4-IP>:9696`
   - Add torrent indexers (The Pirate Bay, 1337x, etc.)
   - Cloudflare-protected indexers will automatically use Byparr
   - They will automatically sync to Sonarr and Radarr

2. **Verify Byparr:** `http://<HC4-IP>:8191`
   - Confirm the service is running
   - You can check the API docs at `/docs`

3. **Create Jellyfin account:** `http://<HC4-IP>:8096`
   - First-time setup wizard
   - Add media libraries for TV shows and movies

4. **(Optional) Configure push notifications:**
   - Install LunaSea or Pushover on mobile
   - Add webhook URLs in Sonarr/Radarr > Settings > Connect

5. **(Optional) Enable remote access:**
   ```bash
   nordvpn set meshnet on
   ```
   Access from anywhere via `<hc4-hostname>.nord:8096`

---

## Service URLs

After deployment, access services at:

| Service | URL | Default Login |
|---------|-----|---------------|
| OpenMediaVault | `http://<HC4-IP>` | admin / openmediavault |
| Transmission | `http://<HC4-IP>:9091` | (none) |
| Prowlarr | `http://<HC4-IP>:9696` | Set on first visit |
| Sonarr | `http://<HC4-IP>:8989` | Set on first visit |
| Radarr | `http://<HC4-IP>:7878` | Set on first visit |
| Jellyfin | `http://<HC4-IP>:8096` | Set on first visit |
| Byparr | `http://<HC4-IP>:8191` | (none) |

---

## Troubleshooting

### Script fails at step 02 (OMV)
- OMV install can take 15-45 minutes. Be patient.
- Check `/root/omv_install.log` for details

### Script fails at step 03 (drive selection)
- Ensure OMV web UI setup is complete and the drive is mounted under `/srv/`
- Check available mounts: `ls -la /srv/`
- Re-run: `sudo ./setup.sh --from 03`

### Script fails at step 04 (NordVPN)
- Ensure `NORDVPN_TOKEN` is set correctly in `config.sh`
- Or leave it empty to skip NordVPN installation entirely
- Check `/var/log/odroid-setup.log` for error details

### Docker containers won't start (step 06)
- Verify `/media` symlink exists: `ls -la /media`
- If missing, re-run drive setup: `sudo ./setup.sh --from 03`

### Service wiring fails (step 07)
- Wait 2-3 minutes after container startup for services to initialize
- Check container logs: `docker logs <container-name>`
- API keys are read from `/home/dietpi/Docker/{Sonarr,Radarr,Prowlarr}/config.xml`

### Reset a specific step
```bash
sudo ./setup.sh --reset 05     # Reset step 05
sudo ./setup.sh --from 05      # Re-run from step 05
```

### View logs
```bash
tail -f /var/log/odroid-setup.log     # Setup script logs
docker logs -f Sonarr                 # Container logs
```

---

## File Structure

```
scripts/
├── config.sh                   # Your configuration (edit this!)
├── setup.sh                    # Main orchestrator
├── lib/
│   └── utils.sh                # Shared functions (logging, state tracking, HTTP polling)
├── steps/
│   ├── 01_fan_control.sh
│   ├── 02_omv_install.sh
│   ├── 03_set_data_drive.sh    # Interactive drive selection, /media symlink
│   ├── 04_nordvpn.sh           # Includes DNS config sub-step
│   ├── 05_docker_install.sh    # Includes daemon DNS config
│   ├── 06_containers.sh        # Includes Byparr container
│   └── 07_wire_services.sh     # Includes Byparr proxy registration
└── templates/
    └── docker-compose.yml.tpl  # Container definitions (includes Byparr)

State tracking:
/var/lib/odroid-setup/*.done    # Completion flags
/var/lib/odroid-setup/backups/  # Config backups
/var/log/odroid-setup.log       # Setup log
```

---

## What's NOT Automated

These steps require physical access or are intentionally manual:

1. **Flashing DietPi to SD card** (do this first on another machine)
2. **PetitBoot bypass** (requires display + keyboard, one-time setup)
3. **OMV RAID/SMB setup** (web UI only, but guided by the script)
4. **Prowlarr indexer credentials** (per-tracker logins for private trackers)
5. **Jellyfin initial setup** (admin account, library paths)

---

## Time Estimate

| Phase | Time |
|-------|------|
| Configuration (`config.sh`) | 2-5 minutes |
| Step 01 (Fan control) | ~30 seconds |
| Step 02 (OMV install) | 20-50 minutes |
| Step 02 (OMV web UI config) | 5-10 minutes |
| Step 03 (Drive selection) | <1 minute |
| Step 04 (NordVPN, optional) | 1-2 minutes |
| Steps 05-07 (Docker, containers, wiring) | 5-10 minutes |
| **Total** | **35-80 minutes** |

Compared to manual setup: **~2-3 hours saved**

---

## Support

For issues with:
- **These scripts:** Open an issue in this repo
- **The manual setup guide:** See the main [README.md](../README.md)
- **Individual services:** Consult their official documentation
