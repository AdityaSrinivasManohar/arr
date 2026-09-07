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
| Env file | `~/arr/.env` (holds PUID, PGID, TZ, NordVPN WireGuard credentials) |

**SSH config block (on your Mac/PC), for reference:**
```
Host arr
    HostName 10.0.0.200
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
│   └── jellyfin/
├── downloads/
│   ├── complete/
│   └── incomplete/
├── movies/
└── tv_shows/            <- note: named tv_shows, not tv (compose maps this to /tv inside containers)
```

---

## Containers & Access

All containers are reachable at `10.0.0.200` on the ports below (except qBittorrent, which shares gluetun's network — see note).

| Container | Purpose | URL / Port | Notes |
|---|---|---|---|
| **Jellyfin** | Media server / streaming | `http://10.0.0.200:8096` | Hardware transcoding via RTX 3060 (NVENC) enabled in Dashboard -> Playback |
| **gluetun** | VPN tunnel (NordVPN WireGuard) | -- (no direct UI) | All qBittorrent traffic routes through this. Killswitch active |
| **qBittorrent** | Torrent client | `http://10.0.0.200:8080` | Runs via `network_mode: service:gluetun` -- connect to it from other containers using host `gluetun`, port `8080`, not `qbittorrent`. Download paths: `/downloads/complete` and `/downloads/incomplete` (incomplete-folder toggle enabled) |
| **Prowlarr** | Indexer manager | `http://10.0.0.200:9696` | Feeds indexers into Sonarr/Radarr. FlareSolverr wired in as an Indexer Proxy for any indexer tagged `flaresolverr` |
| **Sonarr** | TV show tracking/automation | `http://10.0.0.200:8989` | Root folder: `/tv` (maps to `/data/tv_shows`) |
| **Radarr** | Movie tracking/automation | `http://10.0.0.200:7878` | Root folder: `/movies` (maps to `/data/movies`) |
| **Bazarr** | Subtitle automation | `http://10.0.0.200:6767` | Connected to both Sonarr + Radarr; "english" language profile set as default for both |
| **Jellyseerr** | Request front-end | `http://10.0.0.200:5055` | Connected to Jellyfin, Sonarr, Radarr |
| **FlareSolverr** | Cloudflare bypass proxy | `http://10.0.0.200:8191` | Only used by Prowlarr indexers explicitly tagged `flaresolverr` |
| **Profilarr** | Quality profile / custom format management | `http://10.0.0.200:6868` | Replaces the earlier Recyclarr plan -- same goal (TRaSH-style scoring), but with a web UI instead of YAML/CLI |

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

## Quality Profiles (Profilarr)

- Two databases linked in Profilarr: **Dictionarry** (261 custom formats, 11 profiles) and **Dumpstarr** (145 custom formats, 8 profiles)
- Built a custom profile called **"4K to 1080p Cascade"** on top of Dumpstarr's data:
  - Qualities enabled, in priority order: Bluray-2160p -> WEBDL-2160p -> WEBRip-2160p -> Bluray-1080p -> WEBDL-1080p -> WEBRip-1080p
  - Both Remux-2160p and Remux-1080p intentionally **disabled** (this was the fix for the original 11GB-movie-size problem)
  - Custom format scores pulled in via Profilarr's Scoring tab (not hand-set to 0) -- this is what makes Radarr prefer better release groups/sources within a given quality tier, not just accept the first match
- Radarr/Sonarr's Media Management sync settings (Naming, Quality Definitions, Media Settings) are currently pulling from **Dictionarry**, not Dumpstarr -- this is fine, not a conflict, just worth knowing since it's a separate sync category from the quality profile itself
- **Jellyseerr -> Settings -> Services -> Radarr/Sonarr -> Default Quality Profile** set to "4K to 1080p Cascade" so all requests use it automatically (previously was "Any," letting Radarr's own top-level default apply instead)
- Jellyseerr does support a per-request Advanced override (different profile just for one request) if the "Advanced Request" permission is enabled per-user

---

## Apple TV Client

- App: **Swiftfin** (official Jellyfin client, NOT Kotatsu -- that's a manga app)
- Server URL to enter: `http://10.0.0.200:8096`

---

## Still To Do / Known Follow-ups

- **Recyclarr -- abandoned in favor of Profilarr.** Not deployed, no longer part of the plan; ignore any earlier references to `recyclarr.yml`/`secrets.yml`.
- **DHCP reservation** for `10.0.0.200` -- Xfinity's app/admin UI didn't expose this option, so the IP is set statically on the Ubuntu side instead (via netplan) rather than reserved at the router.
- **Lid-close sleep** -- disabled via `/etc/systemd/logind.conf` (`HandleLidSwitch=ignore`, etc.) so the server stays up with the lid closed.
- **Remote access outside home network** -- not yet configured (Tailscale or reverse proxy would be needed for this).
- **Storage expansion** -- currently a single 1TB external HDD; discussed moving to a multi-bay USB DAS enclosure (e.g. 4-bay + two 8TB drives) with mergerfs + SnapRAID for pooling/parity, not yet purchased or set up.
- **Sonarr cascade profile** -- the "4K to 1080p Cascade" profile was built primarily for Radarr; repeat the same Qualities/Scoring setup in Profilarr for Sonarr if the same behavior is wanted for TV shows.
- **Delay Profiles** -- not configured (left at defaults). Would only matter if requesting brand-new/day-one releases and wanting to wait for a better release before grabbing a mediocre one.
