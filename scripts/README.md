# ODROID-HC4 Automated Setup Scripts

Automated installation scripts for setting up an ODROID-HC4 media center with Jellyfin, Sonarr, Radarr, Prowlarr, Transmission, FlareSolverr, and OpenMediaVault.

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
6. Deploy all 6 containers via docker-compose (Transmission, Prowlarr, Sonarr, Radarr, Jellyfin, FlareSolverr)
7. Wire services together via REST APIs (including FlareSolverr proxy registration)
8. Configure Nginx reverse proxy with path-based routing (all services on port 80)

---

## What Gets Automated

| Component | What's Automated | What's Manual |
|-----------|-----------------|---------------|
| **Fan Control** | ✅ Fully automated | None |
| **OpenMediaVault** | ✅ Installation | RAID/SMB/user setup via web UI |
| **Drive Setup** | ✅ Interactive drive selection, `/media` symlink creation | None (interactive prompt) |
| **NordVPN** | ✅ Install, login, subnet detection, P2P connection, autoconnect, DNS config | Generate access token (one-time), or skip entirely |
| **Docker** | ✅ Install Docker Engine, Compose plugin, DNS config, apparmor workaround | None |
| **Containers** | ✅ All 6 containers deployed (Transmission, Prowlarr, Sonarr, Radarr, Jellyfin, FlareSolverr) | None |
| **Service Wiring** | ✅ Prowlarr↔Sonarr/Radarr, Prowlarr↔FlareSolverr proxy, Transmission setup, hardlinks enabled | Add indexers in Prowlarr web UI |
| **Jellyfin** | ✅ Container deployed | Create admin account on first visit |
| **Nginx Proxy** | ✅ Path-based routing on port 80 for all services, base URLs configured | None |

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
   - Note: FlareSolverr is stateless; no config directory needed
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
- Registers FlareSolverr as FlareSolverr-compatible indexer proxy in Prowlarr

**Result:** Once you add indexers in Prowlarr's web UI, they automatically sync to Sonarr and Radarr. Cloudflare-protected indexers automatically use FlareSolverr. Downloads via Transmission are automatically configured.

**Duration:** 1-2 minutes  
**User input:** None

---

### Step 08: Nginx Reverse Proxy

**Automated:**
- Reconfigures OpenMediaVault nginx to listen on port 8080 (removes port 80 conflict)
- Installs Nginx package
- Deploys a dynamic landing page (`nginx-pages/index.html`) with:
  - Service cards with branded icons and descriptions
  - Automatic URL detection (local network vs. NordVPN Meshnet)
  - Mobile-responsive design
  - Single entry point to all services
- Creates reverse proxy configuration with path-based routing
- Configures base URLs for all services (Sonarr, Radarr, Prowlarr, Jellyfin, Transmission)
- Enables WebSocket support for real-time features
- Verifies all endpoints are accessible through the proxy

**What you get:**
- Dynamic landing page at `/` that detects access method and shows appropriate URLs
- All services accessible via port 80 with paths instead of remembering different ports
- Single entry point for both local network and Meshnet access
- Proper proxy headers (X-Forwarded-For, X-Real-IP, etc.)
- 100MB upload size limit for file uploads
- Disabled buffering for Jellyfin media streaming

**Service access after Step 08:**
```
http://<meshnet-hostname>/omv           → OpenMediaVault
http://<meshnet-hostname>/jellyfin      → Jellyfin Media Server
http://<meshnet-hostname>/sonarr        → Sonarr (TV Shows)
http://<meshnet-hostname>/radarr        → Radarr (Movies)
http://<meshnet-hostname>/prowlarr      → Prowlarr (Indexer Manager)
http://<meshnet-hostname>/transmission  → Transmission (Download Client)
```

**Or via local IP:**
```
http://192.168.0.84/omv
http://192.168.0.84/jellyfin
http://192.168.0.84/sonarr
http://192.168.0.84/radarr
http://192.168.0.84/prowlarr
http://192.168.0.84/transmission
```

**Direct port access still works:**
- `http://<HC4-IP>:8080` → OpenMediaVault (moved from 80)
- `http://<HC4-IP>:8096` → Jellyfin
- `http://<HC4-IP>:8989` → Sonarr
- `http://<HC4-IP>:7878` → Radarr
- `http://<HC4-IP>:9696` → Prowlarr
- `http://<HC4-IP>:9091` → Transmission
- `http://<HC4-IP>:8191` → FlareSolverr/FlareSolverr (API-only)

**Duration:** 1-2 minutes  
**User input:** None

**Landing page features:**
- **Smart URL detection:** Automatically detects whether you're accessing via local network or NordVPN Meshnet and displays the appropriate URLs
- **Service cards:** Beautiful branded cards with icons and descriptions for all services
- **Mobile responsive:** Works seamlessly on desktop, tablet, and mobile devices
- **Automatic deployment:** The landing page from `nginx-pages/index.html` is automatically copied to `/var/www/media-center/`
- **Service icons:** Icons from the `images/` directory are deployed alongside the landing page

**Accessing the landing page:**
- Local Network: `http://192.168.0.84/`
- Meshnet: `http://<meshnet-hostname>/` (e.g., `http://rx.sylvain-atlas.nord/`)

**Error handling:**
- APT repository issues are gracefully handled
- OMV port reconfiguration persists even if salt-minion reverts changes
- Jellyfin config uses API with fallback to config file editing
- Transmission config validated before and after modification
- All endpoint verification skips FlareSolverr (API-only service)
- Fallback HTML page created if main landing page file is missing

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
   - Cloudflare-protected indexers will automatically use FlareSolverr
   - They will automatically sync to Sonarr and Radarr

2. **Verify FlareSolverr:** `http://<HC4-IP>:8191`
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

### Via Nginx Reverse Proxy (Recommended - port 80)
| Service | URL | Default Login |
|---------|-----|---------------|
| OpenMediaVault | `http://<HC4-IP>/omv` | admin / openmediavault |
| Transmission | `http://<HC4-IP>/transmission` | (none) |
| Prowlarr | `http://<HC4-IP>/prowlarr` | Set on first visit |
| Sonarr | `http://<HC4-IP>/sonarr` | Set on first visit |
| Radarr | `http://<HC4-IP>/radarr` | Set on first visit |
| Jellyfin | `http://<HC4-IP>/jellyfin` | Set on first visit |

### Direct Port Access (Still Available)
| Service | URL | Default Login |
|---------|-----|---------------|
| OpenMediaVault | `http://<HC4-IP>:8080` | admin / openmediavault |
| Transmission | `http://<HC4-IP>:9091` | (none) |
| Prowlarr | `http://<HC4-IP>:9696` | Set on first visit |
| Sonarr | `http://<HC4-IP>:8989` | Set on first visit |
| Radarr | `http://<HC4-IP>:7878` | Set on first visit |
| Jellyfin | `http://<HC4-IP>:8096` | Set on first visit |
| FlareSolverr | `http://<HC4-IP>:8191` | (none) |

### Via Meshnet (Remote Access)
Replace `<HC4-IP>` with your Meshnet hostname (e.g., `rx.sylvain-atlas.nord`)

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

### Nginx reverse proxy issues (step 08)
- **Services not accessible via proxy:**
  - Check Nginx status: `sudo systemctl status nginx`
  - Verify Nginx config: `sudo nginx -t`
  - Check Nginx error log: `sudo tail -f /var/log/nginx/error.log`
  - Restart Nginx: `sudo systemctl restart nginx`

- **OpenMediaVault on wrong port:**
  - Check OMV nginx config: `cat /etc/nginx/sites-available/openmediavault-webgui`
  - Should have `listen *:8080;` (not 80)
  - Restart OMV: `sudo systemctl restart openmediavault`

- **Jellyfin configuration failed:**
  - Script tries API first, falls back to config file edit
  - Check Jellyfin config: `cat /home/dietpi/Docker/Jellyfin/network.xml`
  - Should have `<BaseUrl>/jellyfin</BaseUrl>`

- **Service not responding on original port:**
  - Verify service is running: `docker ps | grep <service-name>`
  - Check service logs: `docker logs <service-name>`
  - Restart service: `cd /home/dietpi/Docker && docker compose restart <service-name>`

### Reset a specific step
```bash
sudo ./setup.sh --reset 08     # Reset step 08 (nginx)
sudo ./setup.sh --from 08      # Re-run from step 08
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
│   ├── 06_containers.sh        # Includes FlareSolverr container
│   ├── 07_wire_services.sh     # Includes FlareSolverr proxy registration
│   └── 08_nginx_reverse_proxy.sh # Reverse proxy with path-based routing
└── templates/
    └── docker-compose.yml.tpl  # Container definitions (includes FlareSolverr)

State tracking:
/var/lib/odroid-setup/*.done    # Completion flags
/var/lib/odroid-setup/backups/  # Config backups
/var/log/odroid-setup.log       # Setup log

Nginx configuration:
/etc/nginx/sites-available/media-center      # Generated reverse proxy config
/etc/nginx/sites-enabled/media-center        # Symlink to enabled config
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
| Step 08 (Nginx reverse proxy) | 1-2 minutes |
| **Total** | **35-82 minutes** |

Compared to manual setup: **~2-3 hours saved**

---

## Support

For issues with:
- **These scripts:** Open an issue in this repo
- **The manual setup guide:** See the main [README.md](../README.md)
- **Individual services:** Consult their official documentation
