# MediaStack Control Gateway

**Control and query Plex, Tautulli, Sonarr, Radarr, and Lidarr from ChatGPT through a private MCP gateway.**

MediaStack Control Gateway is a Windows Server based MCP gateway for self-hosted media environments. It exposes a defined set of MCP actions for library inspection, metadata management, playlists, reporting, playback state, and controlled Arr administration without exposing the media applications themselves as public Internet services.

**If you find the project useful, please consider donating:**

https://paypal.me/plutoniumshore

## Highlights

- Plex library search, collections, metadata, artwork, playlists, watch state, active sessions, and `addedAt` / Recently Added controls.
- Tautulli-backed reporting for counts, storage, history, statistics, and CSV/JSON exports.
- Sonarr, Radarr, and Lidarr status, health, queue, history, search, additions, updates, bulk quality workflows, wanted/missing items, calendars, and inventory exports.
- Letterboxd-compatible Full, Delta, and Custom CSV exports scoped to the Plex account associated with the configured token.
- OpenAI Secure MCP Tunnel with no public inbound MCP listener required on the gateway host.
- Self-healing Scheduled Tasks with separate liveness/readiness checks, bounded logs, startup grace, and restart cooldowns.
- Destructive Arr deletion protected by a short-lived prepare/confirm token.
- Local credentials stored outside the public installer in a separate configuration file.

Current release: **v3.5.3** with **96 MCP actions**.

## Example Requests

```text
Check Plex status and show my libraries. Do not make any changes.
```

```text
Show the movies in the Alien Collection.
```

```text
Create a playlist from these movies in this order.
```

```text
Show Radarr movies that are missing or below 1080p. Do not change anything yet.
```

```text
Export my Plex movie watch history for Letterboxd.
```

## Deployment Model

The gateway is intended to run natively on Windows Server. The installer uses Windows PowerShell, Windows Scheduled Tasks, NTFS ACLs, and Windows filesystem paths.

Plex, Tautulli, Sonarr, Radarr, and Lidarr can run on the gateway host or on other systems. They only need to be reachable from the gateway server over HTTP or HTTPS.

The MCP server uses stdio behind the OpenAI tunnel client. The tunnel health/admin listener binds to an ephemeral `127.0.0.1` port, so the MCP service itself is not exposed as a public inbound web service.

## Requirements

- Windows Server with Windows PowerShell 5.1 or later.
- Administrator rights for installation.
- A provisioned OpenAI Secure MCP Tunnel and a runtime/control-plane API key authorized to use it.
- Plex Media Server and a valid Plex token.
- Tautulli and API key.
- Sonarr, Radarr, and Lidarr with API keys.
- Network connectivity from the gateway host to those services.
- A ChatGPT environment that supports the custom MCP capabilities you intend to use.

OpenAI MCP capabilities and product availability can change. Refer to the current official documentation when configuring ChatGPT:

- [Developer Mode and MCP apps in ChatGPT](https://help.openai.com/en/articles/12584461-developer-mode-and-full-mcp-connectors-in-chatgpt-beta)
- [OpenAI Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)
- [OpenAI tunnel-client](https://github.com/openai/tunnel-client)

## Installation

1. Download or clone this repository on the Windows gateway server.
2. Copy `MediaStack-Control-Gateway.config.example.psd1` to `MediaStack-Control-Gateway.config.psd1`.
3. Replace every value beginning with `<REQUIRED:` in the local config.
4. Open Windows PowerShell as Administrator.
5. Run:

```powershell
.\Install-MediaStack-Control-Gateway.ps1
```

The installer is idempotent and may be run again after upgrades or configuration changes.

The default managed installation root is:

```text
C:\Scripts\MediaStack-Control-Gateway
```

## Configuration

Environment-specific credentials are stored separately from the installer in the local configuration file. Required values are read from `MediaStack-Control-Gateway.config.psd1`, which is excluded by `.gitignore`.

### Required fields

| Field | Purpose |
| --- | --- |
| `TunnelId` | OpenAI Secure MCP Tunnel ID. |
| `OpenAiRuntimeKey` | Runtime/control-plane API key used by the tunnel client. |
| `PlexUrl` | Plex Media Server base URL. |
| `PlexToken` | Plex authentication token. |
| `TautulliUrl` | Tautulli base URL. |
| `TautulliApiKey` | Tautulli API key. |
| `SonarrUrl` | Sonarr base URL. |
| `SonarrApiKey` | Sonarr API key. |
| `RadarrUrl` | Radarr base URL. |
| `RadarrApiKey` | Radarr API key. |
| `LidarrUrl` | Lidarr base URL. |
| `LidarrApiKey` | Lidarr API key. |

### Optional fields

| Field | Default | Purpose |
| --- | ---: | --- |
| `InstallRoot` | `C:\Scripts\MediaStack-Control-Gateway` | Managed installation directory. |
| `RuntimeLogMaxMB` | `25` | Active tunnel runtime log limit before rotation. |
| `RuntimeLogRetainedFiles` | `3` | Rotated runtime logs retained. |
| `WatchdogLogMaxMB` | `5` | Active watchdog log limit before rotation. |
| `WatchdogLogRetainedFiles` | `3` | Rotated watchdog logs retained. |
| `InstallerLogRetainCount` | `10` | Installer transcripts retained. |
| `WatchdogReadinessFailureThreshold` | `3` | Consecutive readiness failures before recovery. |
| `WatchdogReadinessRestartCooldownMinutes` | `10` | Minimum interval between readiness-triggered restarts. |
| `WatchdogStartupGraceSeconds` | `90` | Grace period after tunnel startup. |
| `WatchdogHealthyHeartbeatMinutes` | `60` | Healthy watchdog heartbeat interval. |

## Plex Capabilities

### Libraries, search, and sessions

- Check Plex status and enumerate libraries.
- Search library items by title and media type.
- Search TV shows and enumerate episodes.
- View active playback sessions and connection/stream details.

### Collections

- List and inspect regular and smart collections.
- Create, rename, and delete collection definitions.
- Add, remove, or replace members of regular collections.
- Preview smart filters before creating collections.
- Update collection summary, sort title, labels, display mode, item order, and promoted visibility.
- Replace collection poster or background artwork.

Deleting a collection removes the collection definition only; it does not delete the underlying media.

### Item and episode metadata

- Read or update movie/show summaries.
- Replace movie/show posters.
- Read or update TV episode title, summary, original air date, content rating, and episode number.
- Preserve unrelated metadata when making targeted edits.

### Playlists

- List regular Plex playlists.
- Read playlist contents in order.
- Create playlists from exact Plex rating keys.
- Add, remove, clear, and delete playlist definitions.
- Create TV playlists from exact `Show Title|S01E02` specifications.

Playlist operations do not delete underlying media.

### Watch state

- Read watched state, view count, progress, duration, and last-viewed time.
- Mark exact movies, shows, seasons, or episodes watched/unwatched.
- Repeated requests are idempotent: requesting a state that is already set does not create another Plex view-count event.

### Plex Touch / `addedAt`

The gateway includes exact and filtered controls for Plex `addedAt`, which determines Recently Added ordering. A client can use these tools to place selected movies, shows, seasons, or episodes into Recently Added without changing the underlying media files.

The companion transient-hub action can request Plex's current hub data and verify Recently Added ordering after an `addedAt` change. It does not scan the library, refresh item metadata, restart Plex, or modify media files.

## Tautulli Reporting

Tautulli provides reporting and analytics without requiring full Plex library inventories to cross the tunnel for ordinary requests.

Supported workflows include:

- Connectivity and Plex-server identity verification.
- Library hierarchy counts and logical media size.
- Largest-item reports and technical media breakdowns.
- Watch history and top/popular statistics.
- Local CSV/JSON metadata exports.
- Chunked transfer of explicitly requested export data.

## Sonarr, Radarr, and Lidarr

The Arr integrations include:

- Connectivity, version, and health checks.
- Queue, history, and command status.
- Root folder, quality profile, tag, and metadata-profile discovery.
- Search/list movies, series, and artists.
- Add movies, series, and artists using explicit root folder/profile selections.
- Duplicate prechecks before additions.
- Post-timeout verification so a successful server-side add is not blindly repeated when the response is lost.
- Update monitoring, profiles, roots, tags, and supported metadata settings.
- Preview and execute controlled bulk quality/monitor/search workflows.
- Wanted/missing and calendar queries.
- Local CSV/JSON inventory exports and storage reports.

### Delete safety

Arr deletion is intentionally two-stage:

1. `arr_prepare_delete` identifies the exact target and returns a short-lived confirmation token.
2. `arr_confirm_delete` accepts only the matching app, item, delete-files choice, and unexpired token.

The token is single-use and expires after 10 minutes.

## Letterboxd Export

`letterboxd_export` creates Letterboxd-compatible UTF-8 CSV files from the Plex account associated with the configured token.

Modes:

- **Full**: all available movie watch history plus watched movies that do not have a usable history date.
- **Delta**: watches since the previous successful Full/Delta checkpoint.
- **Custom**: optional date, library, genre, and title filters without changing the Delta checkpoint.

Exports are stored under the managed `Letterboxd-Exports` directory.

## Tunnel Reliability and Diagnostics

The installer creates a primary tunnel Scheduled Task and a watchdog task. Recovery logic distinguishes process liveness from request readiness and uses consecutive-failure thresholds, startup grace, and restart cooldowns to avoid restart storms.

Runtime and watchdog logs are size-bounded and rotated. Installer transcripts are retained according to configuration.

The gateway also exposes read-only diagnostics for:

- Controlled tunnel response-delay testing.
- Recent runtime restart, timeout, transport, TTL, and gateway-error summaries.

The local tunnel health/admin endpoint is recorded in `tunnel-health-endpoint.txt`. `Open-Tunnel-UI.ps1` reads the current endpoint and opens the tunnel client's local UI.

## What the Installer Downloads

The normal installation path manages its own application-local dependencies:

| Component | Purpose | Source |
| --- | --- | --- |
| OpenAI Secure MCP Tunnel client | Private connection between the local MCP server and supported OpenAI products. | [OpenAI tunnel-client releases](https://github.com/openai/tunnel-client/releases/latest) |
| CPython 3.12.10 | Application-local Python runtime. | [Python on NuGet](https://www.nuget.org/packages/python/3.12.10) |
| MCP Python SDK | MCP server implementation (`mcp[cli]>=2,<3`). | [mcp on PyPI](https://pypi.org/project/mcp/) |
| PlexAPI | Python bindings for Plex Media Server. | [PlexAPI on PyPI](https://pypi.org/project/PlexAPI/) |

When GitHub publishes a SHA-256 digest for the selected tunnel-client archive, the installer verifies the downloaded archive before use.

## Security

- Keep `MediaStack-Control-Gateway.config.psd1` private.
- Do not commit tokens, API keys, tunnel IDs, internal hostnames, or internal addresses.
- The installer applies restricted NTFS ACLs to the local configuration and generated credential-bearing files.
- The tunnel health/admin interface listens only on `127.0.0.1`.
- The MCP server is launched over stdio behind the tunnel client rather than as a public HTTP listener.
- Tunnel diagnostics redact common token/API-key patterns before returning log excerpts.
- Review logs and exports before sharing them publicly because operational data can still reveal local environment details.

## Updating

Replace the installer with the newer production version and run it again from the same directory as the existing local configuration file.

The installer validates the generated MCP schema, updates managed files, stops stale managed tunnel/Python processes when required, and restarts the managed tunnel so the current schema is active. After a release that adds or changes MCP actions, refresh the custom app's discovered actions in ChatGPT.

## v3.5.3 Release Notes

v3.5.3 includes the v3.5.0-v3.5.2 feature set and the final watch-state correction verified against the live gateway:

- Active Plex sessions.
- General regular-playlist management.
- Arr wanted/missing and calendar queries.
- Reversible watched/unwatched state plus read-only state inspection.
- Letterboxd Full/Delta/Custom exports.
- Generated-schema validation and forced runtime refresh.
- Correct post-mutation playlist counts.
- Structured command/poster validation results.
- Arr duplicate-add protection and post-timeout verification.
- Idempotent watched/unwatched writes that do not increment `viewCount` when the requested state already matches.

## Attribution and License

The project uses and integrates third-party software and APIs including OpenAI Secure MCP Tunnel, Python, the Model Context Protocol Python SDK, Plex/PlexAPI, Tautulli, Sonarr, Radarr, and Lidarr. Those components remain subject to their respective licenses and terms.

This repository is provided under the MIT License. See [`LICENSE`](./LICENSE).
