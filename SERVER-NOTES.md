# G14 Media Server — Reference Notes

## Server Access

| Item | Value |
|---|---|
| Hostname | `arr` |
| Static IP | `10.0.0.200` |
| SSH shortcut | `ssh arr` (configured in `~/.ssh/config` on your client machine) |
| SSH user | `adsm` |
| Router gateway | `10.0.0.1` (Xfinity) |
| OS | Ubuntu 26.04.1 |
| GPU | RTX 3060 Mobile (6GB) — NVIDIA driver 595.84, CUDA 13.2 |
| Docker compose location | `~/arr/docker-compose.yml` |
| Env file | `~/arr/.env` (holds PUID, PGID, TZ, NordVPN WireGuard credentials, Tailscale auth key) |

**SSH config block (on your Mac/PC), for reference:**
```
Host arr
    HostName 10.0.0.200
    User adsm
```

Once Tailscale is up, switch `HostName` to the tailnet name so `ssh arr` works from
anywhere (at home it still takes the direct LAN path, so nothing is lost):

```
Host arr
    HostName arr.<your-tailnet>.ts.net
    User adsm
```

---

## Folder Structure (on the server)

```
/data/
├── config/              <- all container configs live here
│   ├── gluetun/
│   ├── qbittorrent/
│   ├── prowlarr/
│   ├── sonarr/
│   ├── radarr/
│   ├── bazarr/
│   ├── jellyseerr/
│   ├── profilarr/
│   ├── jellyfin/
│   └── tailscale/
├── downloads/
│   ├── complete/
│   └── incomplete/
├── movies/
└── tv_shows/            <- qBittorrent/Radarr/Sonarr/Bazarr see these paths identically
                        inside the container (`/data:/data`), so no path translation
```

---

## Containers & Access

All containers are reachable at `10.0.0.200` on the ports below (except qBittorrent, which shares gluetun's network — see note).

| Container | Purpose | URL / Port | Notes |
|---|---|---|---|
| **Jellyfin** | Media server / streaming | `http://10.0.0.200:8096` | Hardware transcoding via RTX 3060 (NVENC) -- **verified working**, see Hardware Transcoding section below |
| **gluetun** | VPN tunnel (NordVPN WireGuard) | -- (no direct UI) | All qBittorrent traffic routes through this. Killswitch active |
| **qBittorrent** | Torrent client | `http://10.0.0.200:8080` | Runs via `network_mode: service:gluetun` -- connect to it from other containers using host `gluetun`, port `8080`, not `qbittorrent`. Download paths: `/data/downloads/complete` and `/data/downloads/incomplete` (incomplete-folder toggle enabled) |
| **Prowlarr** | Indexer manager | `http://10.0.0.200:9696` | Feeds indexers into Sonarr/Radarr. FlareSolverr wired in as an Indexer Proxy for any indexer tagged `flaresolverr` |
| **Sonarr** | TV show tracking/automation | `http://10.0.0.200:8989` | Root folder: `/data/tv_shows`. Library currently empty |
| **Radarr** | Movie tracking/automation | `http://10.0.0.200:7878` | Root folder: `/data/movies`. Imports hardlink from `/data/downloads` -- see Hardlinks section |
| **Bazarr** | Subtitle automation | `http://10.0.0.200:6767` | Connected to both Sonarr + Radarr; "english" language profile set as default for both |
| **Jellyseerr** | Request front-end | `http://10.0.0.200:5055` | Connected to Jellyfin, Sonarr, Radarr. Stores its **own** root folder per service -- update it whenever Radarr/Sonarr root folders change, or every request fails |
| **FlareSolverr** | Cloudflare bypass proxy | `http://10.0.0.200:8191` | Only used by Prowlarr indexers explicitly tagged `flaresolverr` |
| **Profilarr** | Quality profile / custom format management | `http://10.0.0.200:6868` | Replaces the earlier Recyclarr plan -- same goal (TRaSH-style scoring), but with a web UI instead of YAML/CLI |
| **tailscale** | Remote access VPN (mesh) | -- (no direct UI) | Runs `network_mode: host`, so every port in this table is reachable over the tailnet as `arr:<port>`. Admin console at <https://login.tailscale.com/admin/machines> |

---

## Internal Docker Networking Notes

Containers talk to each other using their **container name** as the hostname (not IP), e.g.:
- Sonarr/Radarr -> qBittorrent: use host `gluetun`, port `8080`
- Prowlarr -> Sonarr: use host `sonarr`, port `8989`
- Prowlarr -> Radarr: use host `radarr`, port `7878`
- Jellyseerr -> Jellyfin: use host `jellyfin`, port `8096`
- Bazarr -> Sonarr/Radarr: use host `sonarr` / `radarr`, respective ports
- Profilarr -> Radarr/Sonarr: use `http://radarr:7878` / `http://sonarr:8989` + each app's API key

---

## Hardlinks & the Single `/data` Mount

**qBittorrent, Radarr, Sonarr and Bazarr each mount `/data:/data`** -- one mount,
not separate `/downloads` + `/movies` + `/tv`. This is load-bearing, not cosmetic.
Jellyfin is the exception: it only reads, so it keeps `/data:/media`.

### The bug this fixed

Radarr was silently **copying** every import instead of hardlinking, doubling disk
usage (57G wasted across 5 films). Every obvious check looked healthy:

- "Use Hardlinks instead of Copy" was **on** in Radarr
- `stat -c '%d'` reported the same device (`66306`) for both paths
- Permissions were correct (`PUID`/`PGID` 1000 = `adsm`, owner of everything)

The real cause: **Linux refuses `link()` across different mount points, even on
the same filesystem**, returning `EXDEV` ("Invalid cross-device link"). Two bind
mounts = two mount points, so the kernel refused and Radarr fell back to copying
without surfacing an error anywhere in the UI.

`stat -c '%d'` reports the *superblock*, not the mount -- which is exactly why the
device numbers matched and that test was misleading. Don't trust it for this.

### Ten-second test

```
docker exec radarr sh -c 'touch /data/downloads/.linktest && ln /data/downloads/.linktest /data/movies/.linktest; echo "exit=$?"; rm -f /data/downloads/.linktest /data/movies/.linktest'
```

`exit=0` means hardlinking works. `Cross-device link` means the mount layout is
wrong again. Compare against the host, where it always succeeds (single mount).

### Verify hardlinks exist

```
find /data/movies -type f -links +1        # linked files (library + torrent share one inode)
find /data/downloads/complete -type f -links 1 -size +100M   # orphans: no library counterpart
```

A link count of **1 is normal** once a torrent has been removed -- it only proves
a problem if the file still exists in both trees. Compare inodes to be sure.

### Everything that stores a path (migration checklist)

Changing the mount layout means every app's stored paths must be updated. In order:

1. **qBittorrent** -- default save path, incomplete path, any category save paths,
   then select all torrents -> *Set location* -> `/data/downloads/complete`.
   Safe: the old path no longer exists, so nothing is moved.
2. **Radarr** -- add root folder `/data/movies`, then Movies -> Select all ->
   Root Folder -> **"No, I'll move the files myself"** (same physical directory;
   you only want the DB rewritten). Then delete the old root folder.
3. **Radarr Collections** -- these hold their *own* root folder and throw a
   separate "Missing root folder for movie collection" health warning.
   Collections -> Select all -> Root Folder.
4. **Sonarr** -- same as Radarr, root folder `/data/tv_shows`.
5. **Bazarr** -- confirm Path Mappings are empty; it follows Sonarr/Radarr paths.
6. **Jellyseerr** -- Settings -> Services -> Radarr/Sonarr stores its **own copy**
   of the root folder and sends it with every request. Stale value = every request
   fails with no useful error. This one is easy to forget; it was the last thing
   to break.

In-progress torrents don't survive this cleanly -- *Set location* sets the final
save path, not the incomplete path, and the per-torrent download path can't be
edited in the UI. Easiest to remove them via Radarr -> Activity -> Queue
(**Remove from Download Client** on, **Blocklist** off) and re-search.

### `relink-media.sh`

Lives at `~/arr/relink-media.sh`. For each library file with a link count of 1,
it finds a byte-identical file in `/data/downloads/complete` (exact size match,
then full `cmp`) and replaces the library copy with a hardlink -- links to a temp
name and atomically renames, so an interrupted run can't lose a file. Dry-run by
default; `--apply` to commit. Recovered 54 GiB in one pass.

Useful any time copies sneak in. Run as `adsm`, not root.

---

## VPN (gluetun) Setup Notes

- Provider: NordVPN, custom WireGuard config (server: Columbus, OH -- `columbus.us.wg.nordhold.net`)
- Confirmed working exit IP: `216.183.115.130` (Columbus, OH -- PacketHub S.A. hosting)
- **Correct env vars gluetun actually expects** (current versions use the `WIREGUARD_` prefix, not the older generic `VPN_` prefix): `WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES`, `WIREGUARD_ENDPOINT_IP`, `WIREGUARD_ENDPOINT_PORT`, `WIREGUARD_PUBLIC_KEY`. These map from `.env` values named `NORDVPN_WG_PRIVATE_KEY`, `NORDVPN_WG_ADDRESS`, `NORDVPN_ENDPOINT_IP`, `NORDVPN_WG_PUBLIC_KEY`.
- **Known gotcha:** gluetun's custom WireGuard provider requires a resolved IP for the endpoint, not a hostname -- if the VPN ever breaks unexpectedly, re-resolve the hostname (`dig +short columbus.us.wg.nordhold.net`) and update `NORDVPN_ENDPOINT_IP` in `.env`
- Verify tunnel is up anytime with:
  ```
  docker exec gluetun wget -qO- https://ipinfo.io
  ```

---

## Remote Access (Tailscale)

Chosen over a reverse proxy: no port forwarding, nothing exposed to the public
internet, and the Xfinity gateway never has to cooperate (it already refused to
do a DHCP reservation).

- Runs as a container in `docker-compose.yml` with `network_mode: host`, so
  `tailscale0` lands in the host's network stack and **every published port
  above is reachable over the tailnet** -- no per-service proxying needed.
- `hostname:` cannot be set alongside host networking; the node name comes from
  `TS_HOSTNAME=arr` instead.
- `TS_ACCEPT_DNS=false` on purpose -- MagicDNS resolution happens on the *client*
  side, so the server doesn't need its `resolv.conf` rewritten.
- State lives in `/data/config/tailscale`, so the auth key is only read on the
  very first run.

**Two expiries, easy to confuse:**

| Thing | What it governs | Where |
|---|---|---|
| Auth key expiry (90 days max) | Whether the key can still *register new machines* | Admin console -> Settings -> Keys |
| Node key expiry (default 6 months) | Whether `arr` *stays on the tailnet* | Admin console -> Machines -> `arr` -> Disable key expiry |

The auth key expiring is harmless once `arr` is registered. **Node key expiry is
the one that matters** -- disable it, or the server silently drops off the tailnet
in six months, typically while you're away from home.

- After the first successful start (`docker logs tailscale` ends with `Success.`),
  blank out `TS_AUTHKEY` in `.env`. It's never read again, and a reusable key is a
  live credential that can enroll machines into the tailnet.
- Turn on **MagicDNS** (admin console -> DNS) so every device resolves `arr`.
- Clients needed: Tailscale app on iPhone / Mac / Apple TV, signed into the same
  account. There's a tvOS app, so Swiftfin works remotely too.
- Does **not** conflict with gluetun -- that tunnel is sealed inside its own
  container network namespace, so torrent traffic still exits via NordVPN.
- Trade-off accepted: every client must run Tailscale. Fine for personal devices,
  no good for "watch it at a friend's house." Node sharing or Funnel would cover
  that if it ever comes up.

---

## Quality Profiles (Profilarr)

- Two databases linked in Profilarr: **Dictionarry** (261 custom formats, 11 profiles) and **Dumpstarr** (145 custom formats, 8 profiles)
- **Active profile everywhere is now "Movies 2160p HQ"** -- Radarr, and Jellyseerr's
  default for new requests. Typical results run ~5-13 GB per film.
- **"4K to 1080p Cascade" is no longer in use** (historical): a custom profile built
  on Dumpstarr's data, qualities ordered Bluray-2160p -> WEBDL-2160p -> WEBRip-2160p
  -> Bluray-1080p -> WEBDL-1080p -> WEBRip-1080p, with Remux-2160p and Remux-1080p
  deliberately disabled -- that was the original fix for the 11GB-movie-size problem.
  **Worth confirming "Movies 2160p HQ" also excludes the Remux tiers**, otherwise that
  fix is no longer in effect.
- Custom format scores come from Profilarr's Scoring tab (not hand-set to 0) -- this is
  what makes Radarr prefer better release groups/sources within a quality tier rather
  than accepting the first match
- Radarr/Sonarr's Media Management sync settings (Naming, Quality Definitions, Media Settings) are currently pulling from **Dictionarry**, not Dumpstarr -- this is fine, not a conflict, just worth knowing since it's a separate sync category from the quality profile itself
- **Jellyseerr -> Settings -> Services -> Radarr/Sonarr -> Default Quality Profile** set to
  "Movies 2160p HQ" so all requests use it automatically. That screen also holds the
  **Root Folder** Jellyseerr sends with each request -- see the migration checklist above
- Jellyseerr does support a per-request Advanced override (different profile just for one request) if the "Advanced Request" permission is enabled per-user

---

## Hardware Transcoding (Jellyfin + RTX 3060)

**Verified working end-to-end** -- an `ffmpeg` process shows up under
`nvidia-smi` during playback, not just the settings being ticked.

No compose changes were needed. The LinuxServer image already ships
`NVIDIA_DRIVER_CAPABILITIES=compute,video,utility`, which covers both NVENC/NVDEC
(`video`) and the CUDA tone-mapping pipeline (`compute`). `NVIDIA_VISIBLE_DEVICES`
is unset, and that's fine -- the `deploy.resources.reservations.devices` block
handles device visibility.

Current settings (Dashboard -> Playback -> Transcoding):

- Hardware acceleration: **Nvidia NVENC**
- Hardware decoding: H264, HEVC, VC1, HEVC 10bit, VP9 10bit
- Enhanced NVDEC decoder: on
- Hardware encoding: on
- **Tone mapping: on**, all sub-options at defaults (BT.2390, mode Auto, range
  Auto, desat 0, peak 100). This is the one that matters for 4K -- most 4K is
  HDR10, and transcoding HDR to an SDR client without it gives the washed-out
  grey picture.
- Transcode path: blank (server default, under `/data/config/jellyfin`). Fine
  because `/data` is NVMe.

Still worth ticking:

- **VP9** decode (VP9 10bit is on but plain VP9 isn't -- odd split)
- **AV1** decode -- Ampere supports it, and it's increasingly common on web releases
- **Allow encoding in HEVC format** -- ~30-40% better quality per bitrate than
  H.264, which matters directly for remote streaming over limited upload.
  Jellyfin falls back to H.264 for clients that can't handle it.

**Do not enable AV1 encoding.** The 3060 decodes AV1 but cannot encode it --
NVENC AV1 encode arrived with Ada (RTX 40-series). Ticking it forces a silent
CPU-software fallback that will bury the laptop.

Other notes:

- If highlights ever look blown out, switch **Tone mapping mode** to `RGB`.
- Cap **internet streaming bitrate** (Dashboard -> Playback) for remote viewing --
  residential upload is the real ceiling, and the GPU transcodes down to fit.
- Consumer GeForce cards limit concurrent NVENC sessions. Irrelevant for a
  household, relevant if several people ever stream at once.
- `nvidia-smi` reporting absurd wattage (e.g. `752W / 64W`) is a known mobile-GPU
  sensor artifact, not a real reading.

Verify anytime:
```
docker exec jellyfin printenv NVIDIA_DRIVER_CAPABILITIES
docker exec jellyfin /usr/lib/jellyfin-ffmpeg/ffmpeg -hide_banner -filters | grep tonemap_cuda
docker exec jellyfin nvidia-smi        # during playback: expect an ffmpeg process
```

---

## Apple TV Client

- App: **Swiftfin** (official Jellyfin client, NOT Kotatsu -- that's a manga app)
- Server URL to enter: `http://10.0.0.200:8096` (or `http://arr:8096` once MagicDNS
  is on -- same URL works at home and away)
- For remote viewing the Apple TV needs the **Tailscale tvOS app** installed and
  signed in. tvOS sometimes deprioritizes background VPN; if playback fails after
  a long idle, open the Tailscale app once to wake it.

---

## Still To Do / Known Follow-ups

- **Recyclarr -- abandoned in favor of Profilarr.** Not deployed, no longer part of the plan; ignore any earlier references to `recyclarr.yml`/`secrets.yml`.
- **DHCP reservation** for `10.0.0.200` -- Xfinity's app/admin UI didn't expose this option, so the IP is set statically on the Ubuntu side instead (via netplan) rather than reserved at the router.
- **Lid-close sleep** -- disabled via `/etc/systemd/logind.conf` (`HandleLidSwitch=ignore`, etc.) so the server stays up with the lid closed.
- **Storage expansion** -- `/data` currently lives on the internal **NVMe** drive (single disk, no redundancy). Discussed moving bulk media to a multi-bay USB DAS enclosure (e.g. 4-bay + two 8TB drives) with mergerfs + SnapRAID for pooling/parity, not yet purchased or set up. Keeping transcode scratch on the NVMe is worth preserving through any such move.
- **Sonarr quality profile** -- Sonarr has no library yet. Decide on a profile there when TV gets added; the "4K to 1080p Cascade" work was Radarr-only and is now superseded by "Movies 2160p HQ" anyway.
- **Move configs out of `/data`** -- `/data/config` sits inside the shared `/data:/data` mount, so those four containers can see every app's config (API keys, qBittorrent credentials). Relocating to `/opt/appdata` needs no app-side changes (the in-container `/config` path stays the same) and would also let Jellyfin's broad `/data:/media` mount be narrowed.
- **Delay Profiles** -- not configured (left at defaults). Would only matter if requesting brand-new/day-one releases and wanting to wait for a better release before grabbing a mediocre one.
