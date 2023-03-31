# ODROID-HC4 Media Center Setup

This page will guide you through the setup of a media center on an [ODROID-HC4](https://www.hardkernel.com/shop/odroid-hc4/). The end goal is to have a platform where you can watch, download, and store content in a user friendly manner.

Main features:
- Media server: [Jellyfin](https://jellyfin.org).
- TV show collection manager and downloader: [Sonarr](https://sonarr.tv). 
- Movie collection manager and downloader: [Radarr](https://radarr.video).
- NAS: [OpenMediaVault](https://www.openmediavault.org).



## Table of Contents

1. [Basic Configuration](#1-basic-configuration "Goto 1. Basic Condguration")
2. [NordVPN](#2-nordvpn "Goto 2. NordVPN")
3. [OpenMediaVault](#3-openmediavault "Goto 3. OpenMediaVault") 
4. [Docker and Portainer](#4-Docker-and-Portainer "Goto 4. Docker and Portainer")
5. [Transmission](#5-Transmission "Goto 5. Transmission")
6. [Prowlarr](#6-Prowlarr "Goto 6. Prowlarr")
7. [Sonarr](#7-Sonarr "Goto 7. Sonarr")
8. [Radarr](#8-Radarr "Goto 8. Radarr")
9. [Jellyfin](#9-jellyfin "Goto 9. Jellyfin")
10. [Watchtower](#10-watchtower "Goto 10. Watchtower")

## Extras
1. [Push Notifications](#1-Push-Notifications "Goto 1. Push Notifications")
2. [Access your HC4 remotely](#2-Access-your-HC4-remotely "Goto 2. Access your HC4 remotely")
3. [Jellyseerr](#3-jellyseerr "Goto 3. Jellyseerr")
4. [PetitBoot Recovery](#4-PetitBoot-Recovery "Goto 4. PetitBoot Recovery")



&nbsp;
## 1. Basic configuration 

### 1.1 Install DietPi

[DietPi](https://dietpi.com) is a minimal version of Debian, designed to use less CPU power and have a lower RAM usage.

1. Flash [DietPi_OdroidC4-ARMv8-Bullseye.img](https://dietpi.com/downloads/images/DietPi_OdroidC4-ARMv8-Bullseye.7z) ([alternative link](https://www.dropbox.com/s/9j2basmljzzpw20/DietPi_OdroidC4-ARMv8-Bullseye.7z?dl=0)) on an SD card using [Etcher](https://www.balena.io/etcher) or [dd](https://askubuntu.com/a/377561).
2. Insert the SD card in the HC4, then wait until you can see it connected to your network.
3. Connect via ssh using usr:root pwd:dietpi.
4. Complete the installation process.

### 1.2. Boot Automatically on DietPi

The HC4 uses [PetitBoot](https://manpages.ubuntu.com/manpages/xenial/man8/petitboot.8.html) as a bootloader, which is currently not compatible with DietPi. It mean that on startup, PetitBoot won’t boot on the OS automatically. This can be bypassed by pressing the boot switch under the case while booting.

In order to automatically boot on the DietPi, you must bypass Petitboot. 
1. Remove the SD card.
2. Start the HC4 and wait for PetitBoot to load.
3. Select "Exit to shell".
4. Empty the SPI flash memoty, which will allow to automatically boot on the SD card, by executing:

```
flash_eraseall /dev/mtd0
flash_eraseall /dev/mtd1
flash_eraseall /dev/mtd2
flash_eraseall /dev/mtd3
```
4. Restart the HC4, it will now boot on DietPi
5. ssh into DietPi by executing: `ssh root@<HC4-IP>`, with "dietpi" for the password.

**Note:** Refer to [PetitBoot Recovery](#4-PetitBoot-Recovery "Goto 4. PetitBoot Recovery") in order to restore it if needed.

### 1.3 Start the Fan

The fan won't work out of the box, the following setup needs to be done.
1. Install fancontrol by executing: `sudo apt install fancontrol`.
2. Add the following configuration for fancontrol in /etc/fancontrol.
```
INTERVAL=10
DEVPATH=hwmon0=devices/virtual/thermal/thermal_zone0 hwmon2=devices/platform/pwm-fan
DEVNAME=hwmon0=cpu_thermal hwmon2=pwmfan
FCTEMPS= hwmon2/pwm1=hwmon0/temp1_input
FCFANS= hwmon2/pwm1=hwmon2/fan1_input
MINTEMP= hwmon2/pwm1=35
MAXTEMP= hwmon2/pwm1=70
MINSTART= hwmon2/pwm1=10
MINSTOP= hwmon2/pwm1=10
MINPWM= hwmon2/pwm1=10
```
3. In order to start fancontrol now, and have it started on startup, execute: `sudo systemctl enable fancontrol`.



&nbsp;
## 2. NordVPN

[NordVPN](https://nordvpn.com/) will be your VPN used in order to download safely.  

### 2.1 Install and Log In

1. Install NordVPN by executing: `sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)`
2. Log in to NordVPM
    1. Generate an access token via [the NordVPN Dashboad](https://my.nordaccount.com/dashboard/nordvpn/).
    2. Execute: `nordvpn login --token <token>`

### 2.2 Configure NordVPN

1. Disable NordVPN for all incoming local connections, among other, it will allow to still being able to connect to DietPi via SSH
    1. Find your subnet mask by executing: `ip -o -f inet addr show`. Example: if you get `192.168.0.84/24` then your subnet is `192.168.0.0/24`.
    2. Then execute: `nordvpn whitelist add subnet <subbnet>`, the subnet used here is an example.
2. Connect the the P2P server by executing: `nordvpn connect P2P`. If the SSH sesion was not ended, the configuration was done properly, move to the next step. Else, restart the HC4.
3. Enable auto-connect so NordVPN will start on startup..
    1. Retrieve the server id of the P2P server by executing: `nordvpn status`. It should look like this: "ca1628".
    2. Execute: `nordvpn set autoconnect on <server. id>`.



&nbsp;
## 3. OpenMediaVault

[OpenMediaVault](https://www.openmediavault.org) will allow you to setup your data storage and install Docker and Portainer.

### 3.1. Install OpenMediaVault

Install OpenMediaVault by executing:

`wget -O - https://github.com/OpenMediaVault-Plugin-Developers/installScript/raw/master/install | sudo bash`

### 3.2. Set up

The command above should have also installed omv-extra which will allow to install Portainer and Docker.
1. Go to `http://<HC4-IP>`.
2. Log in to OpenMediaVault usin the "admin" account with "openmedivault" as the password.
3. In System, make sure that you see "omv-extras". If it doesn't appear, install it.
4. If you have multiple drives, setup them with RAID 0 or above.
    1. Go to Storage > Software RAID, and click on +.
    2. Select the RAID level you want to use, then the hard drives or SSD. Save.
5. Create a symlink to your RAID array or drive by executing `ln -s /your-drive-location /data`.
6. Create an SMB share of your data folder.
    1. Go to Storage > Shared Folders, click on +.
    2. Fill in the form, using your drive or RAID array for the File System.
    3. Go to Services > SMB/CIFS > Settings. Enable and save.
    4. Go to Services > SMB/CIFS > Shares. Click on +. 
    5. Fill in the form, selecting your shared folder, and setting "No" for the public field. Save.
7. Create a user
    1. Go to Users > Users, click on +.
    2. Fill in the form, save. 
8. Use your user to connect to your SMB share.


&nbsp;
## 4. Docker and Portainer

[Portainer](https://www.portainer.io) is a Docker container manager that comes with a convenient UI.

Via omv-extras in OMV: 
1. Install Docker, then reboot.
2. Then install Portainer, then reboot. Note: After trying, a generic error message was displayed. Installing the following packages fixed it: `apt install apparmor apparmor-utils auditd`
3. Go to `http://<HC4-IP>:9000`.



&nbsp;
## 5. Transmission

[Transmission](https://transmissionbt.com) is the BitTorrent client that will be used by Sonarr and Radarr.

1. Create the following directories:
  - /home/dietpi/Docker/Transmission
  - /home/dietpi/Docker/Transmission/watch
  - /data/torrents

2. Deploy Transmission by executing:
```
# Use your own time zone for TZ https://w.wiki/4Jx
docker run --detach \
  --name Transmission \
  --env PUID=1000 \
  --env PGID=1000 \
  --env TZ=Canada/Eastern \
  --publish 9091:9091 \
  --publish 51413:51413 \
  --publish 51413:51413/udp \
  --volume /home/dietpi/Docker/Transmission:/config \
  --volume /home/dietpi/Docker/Transmission/watch:/watch \
  --volume /data/torrents:/downloads \
  --restart unless-stopped \
  lscr.io/linuxserver/transmission:latest
```
[documentation](https://hub.docker.com/r/linuxserver/transmission)

2. Go to: `http://<HC4-IP>:9091`.

[Prowlarr](https://prowlarr.com) is an torrent indexer manager/proxy. Those indexers will be used by Sonarr and Radarr to download content. 

&nbsp;
## 6. Prowlarr

### 6.1. Install

1. Create the following directory: /home/dietpi/Docker/Prowlarr.
2. Deploy Prowlarr by executing:
```
# Use your own time zone for TZ https://w.wiki/4Jx
docker run --detach \
  --name=Prowlarr \
  --env PUID=1000 \
  --env PGID=1000 \
  --env TZ=Canada/Eastern \
  --publish 9696:9696 \
  --volume /home/dietpi/Docker/Prowlarr:/config \
  --restart unless-stopped \
  lscr.io/linuxserver/prowlarr:latest
```
[documentation](https://hub.docker.com/r/linuxserver/prowlarr)

3. Go to: `http://<HC4-IP>:9696`.

### 6.2. Add Indexers

1. Go to  Indexer and press "Add Indexer".
2. Add the indexers you want to use such as "The Pirate Bay", "RarBg", "1337x", ...

### 6.3 Add Transmission as a Download Client

1. Go to Settings > Download Clients.
2. Click Add then select Transmission.
3. Fill in the form and save.



&nbsp;
## 7. Sonarr

[Sonarr](https://sonarr.tv) is a tv show collection manager. It will allow you to download tv shows via BitTorrent using torrent files from indexers provided by Prowlarr.

### 7.1. Install

1. Create the following directories: 
  - /home/dietpi/Docker/Sonarr.
  - /data/media/tv
2. Deploy Sonarr by executing:

```
# Use your own time zone for TZ https://w.wiki/4Jx
docker run --detach \
  --name=Sonarr \
  --env PUID=1000 \
  --env PGID=1000 \
  --env TZ=Canada/Eastern \
  --publish 8989:8989 \
  --volume /home/dietpi/Docker/Sonarr:/config \
  --volume /data/media/tv:/tv `#optional` \
  --volume /data/torrents:/downloads \
  --restart unless-stopped \
  lscr.io/linuxserver/sonarr:latest
```
[documentation](https://hub.docker.com/r/linuxserver/sonarr)

3. Go to: `http://<HC4-IP>:8989`.

### 7.2. Scan you TV show library

1. Go to Series > Library Import.
2. Press Import Existing TV Shows

### 7.3. Add Sonarr as an app in Prowlarr

1. In Prowlarr, go to Settings > Apps
2. Click Add then select Sonarr
3. In the form, an API key is needed. To retrieve it open Sonarr and go to Settings > General
4. Fill in the form and save
5. In Sonarr, go to Settings > Indexers. After waiting a for bit, you should now see the Indexers you added to Prowlarr

### 7.4. Use hard links instead of copies when sorting downloaded files

Instead of duplicating a file when adding it to the tv show directory, hardline can be used to avoid this data duplication.

1. Go to Settings > Media Management.
2. Press the "Show Aadvanced" button in the top bar.
3. Check "Use Hardlinks instead of Copy".

### 7.5. Add transmission

1. Go to Settings > Download Clients
2. Fill in the form, and at the bottom, check "Remove Completed" in order to delete the file after it was moved.

### 7.6. Setup Profiles

You can apply quality or language profiles to your TV Show in order for Sonarr to select a torrent file fit for your needs.
1. Go to Settings > Profiles.
2. Update profiles according to your needs.
3. Go to Series, open a serie and change the profile.



&nbsp;
## 8. Radarr

[Radarr](https://radarr.video) is a movie collection manager. It will allow you to download movies via BitTorrent using torrent files from indexers provided by Prowlarr.  

### 8.1. Install

1. Create the following directories: 
  - /home/dietpi/Docker/Radarr
  - /data/media/movies
2. Deploy Sonarr by executing:
```
# Use your own time zone for TZ https://w.wiki/4Jx
docker run --detach \
  --name=Radarr \
  --env PUID=1000 \
  --env PGID=1000 \
  --env TZ=Canada/Eastern \
  --publish 7878:7878 \
  --volume /home/dietpi/Docker/Radarr:/config \
  --volume /data/media/movies:/movies \
  --volume /data/torrents:/downloads \
  --restart unless-stopped \
  lscr.io/linuxserver/radarr:latest
```
[documentation](https://hub.docker.com/r/linuxserver/radarr)

3. Go to: `http://<HC4-IP>:7878`.

### 8.2. Scan your Movies library

1. Go to Series > Library Import.
2. Press Import Existing Movies.

### 8.3. Add Radarr as an app in Prowlarr

1. In Prowlarr, go to Settings > Apps
2. Click Add then select Radarr
3. In the form, an API key is needed. To retrieve it open Radarr and go to Settings > General
4. Fill in the form and save
5. In Radarr, go to Settings > Indexers. After waiting for a bit, you should now see the Indexers you added to Prowlarr

### 8.4. Use hard links instead of copies when sorting downloaded files

Instead of duplicating a file when adding it to the tv show directory, hardline can be used to avoid this data duplication.

1. Go to Settings > Media Management.
2. Press the "Show Aadvanced" button in the top bar.
3. Check "Use Hardlinks instead of Copy".

### 8.5. Add transmission

1. Go to Settings > Download Clients.
2. Fill in the form, and at the bottom, check "Remove Completed" in order to delete the file after it was moved.

### 8.6. Setup Profiles

Contratily to Sonarr, Radarr has only one type of profile which contains both the quality and the language. You may want to edit each profile's language to set it to "Original", if so, do the following.
1. Go to Settings > Profiles.
2. Edit each profile's language to set it to "Original".



&nbsp;
## 9. Jellyfin

[Jellyfin](https://jellyfin.org) is the media server that you will use to access your movies and tv shows. 

### 9.1. Install

1. Create the following directory: /home/dietpi/Docker/Jellyfin
2. Deploy Jellyfin by executing:
```
# Use your own time zone for TZ https://w.wiki/4Jx
docker run --detach \
  --name=Jellyfin \
  --env PUID=1000 \
  --env PGID=1000 \
  --env TZ=Canada/Eastern \
  --publish 8096:8096 \
  --publish 7359:7359/udp `#optional` \
  --publish 1900:1900/udp `#optional` \
  --volume /home/dietpi/Docker/Jellyfin:/config \
  --volume /data/media/tv:/data/TVShows \
  --volume /data/media/movies:/data/Movies \
  --restart unless-stopped \
  lscr.io/linuxserver/jellyfin:latest
```
[documentation](https://hub.docker.com/r/linuxserver/jellyfin)

3. Go to: `http://<HC4-IP>:8096` and setup your account.

### 9.2. Transcoding
1. Go to the playback section of the administration dashboard.
2, Under Hardware Acceleration, select "Video Acceleration API (VAAPI)".
3. Enable hardware encoding for all types.
4. Set transcoding thread count to max.
5. Set encoding preset to slow. Adjust it if needed.


&nbsp;
## 10. Watchtower

[Watchtower](https://containrrr.dev/watchtower/) will keep your docker container updated. 

Create and run a Watchtower container that will schedule updates at 4am everyday, and delete old images after updating.
Do so by executing:

```
# Use your own time zone for TZ https://w.wiki/4Jx
docker run --detach \
  --name Watchtower \
  --env WATCHTOWER_SCHEDULE="* * 4 * * *" \
  --env TZ=Canada/Eastern \
  --env WATCHTOWER_CLEANUP="true" \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  --restart unless-stopped \
  containrrr/watchtower
```
[documentation](https://containrrr.dev/watchtower/)



&nbsp;
## Extras
&nbsp;



## 1. Push Notifications

In order to enable push notification on your devices when a movie or TV show is downloaded (and more), use either LunaSea or Pushover (not free):

### 1.1 Using LunaSea

1. Install the LunaSea app ([iOS](https://apps.apple.com/us/app/lunasea/id1496797802) or [Android](https://play.google.com/store/apps/details?id=app.lunasea.lunasea)).
2. In LunaSea
    1. Go to Settings > Configuration > Sonarr/Radarr > Connection Details.
    2. Fill in Host and API Key. To retrieve the API key, in Sonarr/Radarr, go to Settings > General.
    3. In LunaSea, go to Settings > Notifications > Sonarr/Radarr and press on Device to copy the URL. Alternatively, to get the notification on all your devices with LunaSea installed, you can create a LunaSea account an copy the User URL.
3. In Sonarr/Radarr, 
    1. Settings > Connect, and click on +.
    2. Select Webhook and fill in the Name and URL fields using the URL you copied from LunaSea
    3. Click on Save and you should get a test notification.

### 1.2 Using Pushover

1. Install the Pushover app ([iOS](https://apps.apple.com/us/app/pushover-notifications/id506088175) or [Android](https://play.google.com/store/apps/details?id=net.superblock.pushover)).
2. Create an account.
3. In [Pushover.net](https://pushover.net).
    1. Log in.
    2. Get your User Key.
    3. Press Create an Application/API Token.
4. Add Pushover to Radarr and Sonarr. For both, do:
    1. Setting > Connect, click on +.
    2. Select Pushover, fill in the form.
    3. Save, and you should receive a confirmation code,



## 2. Access your HC4 remotely

To access your HC4, you can use NordVPN Meshnet which is a feature that allows to access a remote device from outside of your local network.

1. Enable Meshnet on the HC4 by executing: `nordvpn set meshnet on`.
2. Enable Meshnet on the client device you want to access your HC4 from.
3. Execute: `nordvpn meshnet peer list`, you should see the client device and the HC4 with its hostname.
4. From your client device, use the HC4's hostname to access services running on it. Such as `hc4-hostname.nord:8096` for Jellyfin.



## 3. Jellyseerr

[Jellyseerr](https://github.com/Fallenbagel/jellyseerr) allows to manage requests to Sonarr and Radarr as well as suggesting new movies and TV shows based on your Jellyfin libreary.

### 3.1 Install Jellyseerr

Create and run Jellyseerr container by executing:

```
docker run -d \
  --name Jellyseerr \
  --env TZ=Canada/Eastern \
  --publish 5055:5055 \
  --volume /home/dietpi/Docker/Jellyseerr:/app/config \
  --restart unless-stopped \
  fallenbagel/jellyseerr:latest
```

### 3.2 Setup

1. Sign-in using Jellyfin, scan for repositories on Jellyfin, select collections, movies, tv shows.
2. Add your Sonarr and Radarr server informations.



## 4. PetitBoot Recovery

If you need to re-enable PetitBoot after doing the process to bypass it, do:

1. Flash [spiupdate_odroidhc4_20201222](http://ppa.linuxfactory.or.kr/images/petitboot/odroidhc4/spiupdate_odroidhc4_20201112.img.xz) ([alternative link](https://www.dropbox.com/s/lr26ggpv9q7agfk/spiupdate_odroidhc4_20201112.img.xz?dl=0)) on an SD card using [Etcher](https://www.balena.io/etcher) or [dd](https://askubuntu.com/a/377561).
2. Insert the SD card in the HC4, connect an external display.
3. Press the the button under the card and insert the power plug. Keep pressing until the blue line appears.
4. Change the boot order (may not be necessary)
    1. Select "System Configuration" in the menu
    2. Modify the boot order to have:
        1. "disk: mmcblk1p1 [uuid 7A55-39C4]" // the SD card
        2. "Any Network device"
        3. "Any Device"
    3. Select OK at the bottom of the menu.
5. Restart the HC4 with the SD card still in it, and wait for the recovery to finish.



&nbsp;
## Ressources
- [DietPi - dietpi.com](https://dietpi.com/)
- [Bootloader bypass method - armbian.com](https://www.armbian.com/odroid-hc4/)
- [Fanspeed control using ‘fancontrol' - linuxfactory.com](https://docs.linuxfactory.or.kr/guides/sensors.html#fanspeed-control-using-fancontrol)
- [OMV install script - github.com/OpenMediaVault-Plugin-Developers](https://github.com/OpenMediaVault-Plugin-Developers/installScript/)
- ["How to restore Petitboot on HC-4" - odroid.com](https://forum.odroid.com/viewtopic.php?f=207&t=40906)
- [Installing NordVPN on Linux distributions - NordVPN.com](https://support.nordvpn.com/Connectivity/Linux/1325531132/Installing-and-using-NordVPN-on-Debian-Ubuntu-Raspberry-Pi-Elementary-OS-and-Linux-Mint.htm)
- [Portainer - Docker.com](https://hub.docker.com/r/portainer/portainer)
- [Transmisson - Docker.com](https://hub.docker.com/r/linuxserver/transmission)
- [Prowlarr - Docker.com](https://hub.docker.com/r/linuxserver/prowlarr)
- [Sonarrr - Docker.com](https://hub.docker.com/r/linuxserver/sonarr)
- [Radarr - Docker.com](https://hub.docker.com/r/linuxserver/radarr)
- [Jellyfin - Docker.com](https://hub.docker.com/r/linuxserver/jellyfin)
- [Hardlinks - trash-guides.info](https://trash-guides.info/Hardlinks/Hardlinks-and-Instant-Moves/)
- [Watchtower Documentation - containrrr.dev](https://containrrr.dev/watchtower/)
- [Radarr notifications - lunasea.app](https://docs.lunasea.app/lunasea/notifications/radarr)
- [Sonarr notifications - lunasea.app](https://docs.lunasea.app/lunasea/notifications/sonarr)
- [How to use Meshnet on Linux - nordvpn.com](https://support.nordvpn.com/General-info/Features/1872910282/How-to-use-Meshnet-on-Linux.htm)
- [Jellyseer - github.com/Fallenbagel](https://github.com/Fallenbagel/jellyseerr)
- [PetitBoot images - linuxfactory.or.kr](http://ppa.linuxfactory.or.kr/images/petitboot/odroidhc4/)
