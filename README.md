# MediaStack Control Gateway

**Control and query your Plex media environment from ChatGPT using natural-language commands.**

MediaStack Control Gateway is a Windows Server based MCP gateway that lets ChatGPT act as a conversational control and reporting interface for Plex, Tautulli, Sonarr, Radarr, and Lidarr. It is designed for self hosted environments where the media applications may be private, local, or distributed across multiple systems.

The gateway exposes a deliberately defined set of MCP actions rather than giving ChatGPT unrestricted access to the host. It can inspect libraries, manage Plex collections and metadata, update artwork, report storage and activity, change Plex `addedAt` metadata for Recently Added ordering, query Tautulli, and perform controlled Sonarr/Radarr/Lidarr administration.

**If you find anything here useful, please consider donating:**

https://paypal.me/plutoniumshore

## What This Project Does

Typical ChatGPT requests can include:

```text
Check Plex status and show my libraries. Do not make any changes.
```

```text
Show me the movies in the Alien Collection.
```

```text
Touch all movies featuring Tim Curry.
```

```text
Update this episode's summary and original air date.
```

```text
Show Sonarr series that have files below 1080p, but do not change anything yet.
```

```text
How much logical media storage is represented in each Plex library?
```

The gateway is a control and reporting layer. It does not replace Plex, Tautulli, Sonarr, Radarr, or Lidarr.

## Intended Deployment

**The gateway itself is intended to run natively on Windows Server. It is not designed as a Docker or container deployment.**

The installer uses Windows PowerShell, Windows Scheduled Tasks, Windows ACLs, and Windows filesystem paths. Run it from an elevated Windows PowerShell session.

Plex, Tautulli, Sonarr, Radarr, and Lidarr do not have to run on the gateway server. They only need to be reachable by HTTP from the Windows server hosting MediaStack Control Gateway.

This repository assumes those media applications already exist and are working. Installing or configuring Plex, Tautulli, Sonarr, Radarr, or Lidarr is outside the scope of this project.

## Tested Configuration

Development and testing have primarily used:

* ChatGPT Business.
* ChatGPT Developer Mode with a custom MCP app.
* OpenAI Secure MCP Tunnel.
* Windows Server as the gateway host.
* Plex Media Server associated with an active Plex Pass membership.
* Tautulli.
* Sonarr.
* Radarr.
* Lidarr.

Plex Pass is **not currently believed to be required for the core gateway functionality** such as collection management and metadata editing. The project has, however, been developed and tested against a Plex server associated with an active Plex Pass membership. Environments without Plex Pass have not been comprehensively tested. Plex features that independently require Plex Pass still require it.

## ChatGPT and OpenAI Requirements

Custom MCP capabilities change over time, so check the current OpenAI documentation before deployment.

As of September 2026:

* Full custom MCP support, including write and modify actions, is available to supported ChatGPT Business, Enterprise, and Edu workspaces.
* Pro users can use custom MCP connections with read/fetch permissions, but full write/modify MCP is not currently available to Pro.
* Custom MCP apps are currently used from ChatGPT web.
* A private, on premises, or local MCP server cannot be connected directly to ChatGPT. OpenAI Secure MCP Tunnel is used to bridge the private gateway without publishing a public inbound service.
* Developer Mode and workspace permissions may need to be enabled by a ChatGPT workspace administrator or owner.

Official references:

* [Developer Mode and MCP apps in ChatGPT](https://help.openai.com/en/articles/12584461-developer-mode-and-full-mcp-connectors-in-chatgpt-beta)
* [OpenAI Secure MCP Tunnel guide](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)
* [OpenAI tunnel-client](https://github.com/openai/tunnel-client)
* [OpenAI tunnel management](https://platform.openai.com/settings/organization/tunnels)
* [OpenAI runtime API keys](https://platform.openai.com/settings/organization/api-keys)

## Capabilities

### Plex Libraries and Search

The gateway can:

* Check Plex server status and enumerate libraries.
* Search library content by title and media type.
* Search television shows and find/list episodes.
* Create narrowly scoped TV episode playlists.

### Plex Collections

The gateway supports regular and smart collections, including:

* List and inspect collections.
* Create, rename, and delete collection definitions.
* Add, remove, and replace members of regular collections.
* Preview smart collection filters before creating or changing them.
* Create and update smart collection filters.
* Read and update collection summaries, labels, sort titles, display modes, item order, and promoted visibility.
* Replace collection posters and background artwork.

Deleting a Plex collection deletes the **collection definition only**. It does not delete the movies, shows, music, or other underlying media files.

### Individual Plex Metadata

The gateway can read or update selected metadata while preserving unrelated fields:

* Movie and TV show summaries.
* Movie and TV show posters.
* Individual TV episode title.
* Individual TV episode summary.
* Individual TV episode original air/release date.
* Individual TV episode content rating.
* Individual TV episode number within its existing season.

Manual metadata edits are locked where appropriate so an ordinary Plex metadata refresh does not immediately overwrite them.

### Plex Touch and `addedAt`

**Plex Touch** is the user-facing convention for changing Plex `addedAt` metadata so selected media appears in Recently Added.

The underlying MCP tools remain technically named:

* `plex_get_item_added_at`
* `plex_set_items_added_at`
* `plex_set_filtered_items_added_at`

Touch can target exact movies, shows, seasons, episodes, or filtered selections such as an actor, director, or collection.

Examples:

```text
Touch all movies featuring Dolly Parton.
```

```text
Touch all television shows featuring Tim Curry.
```

```text
Touch the Alien Collection.
```

```text
Touch all movies directed by John Carpenter.
```

Touch modifies **Plex metadata only**. It does not:

* Change filesystem timestamps.
* Move media files.
* Rename media files.
* Delete media.
* Rematch media.
* Redownload media.

The supplied item order can be staggered by seconds so Plex receives an unambiguous Recently Added order.

### Plex Transient-Hub Refresh

`plex_refresh_library_hubs` non-destructively requests the transient Plex hubs for one library and then verifies the server's current Recently Added ordering directly from `addedAt`.

This is intentionally described as a **refresh/warm/cache nudge**, not guaranteed cache invalidation.

It does not:

* Scan the library.
* Refresh all metadata.
* Restart Plex Media Server.
* Delete Plex cache files.
* Change metadata.
* Move or modify media files.

Individual Plex clients may still retain their own locally cached Home or Recently Added rows for a period of time.

A useful ChatGPT convention is to treat a Touch operation as:

```text
Touch -> verify addedAt -> refresh affected library hubs -> verify Recently Added ordering
```

The gateway exposes both actions separately so the behavior remains explicit and auditable. The Recommended ChatGPT Memory section below provides a copyable convention that asks ChatGPT to perform the refresh automatically after Touch.

### Tautulli Reporting

Tautulli is used as a reporting and analytics source. The gateway can:

* Verify Tautulli connectivity and Plex server identity.
* Report library counts and hierarchy statistics.
* Report logical media storage.
* Return largest items.
* Group cached media by selected technical fields.
* Query watch history and top statistics.
* Start local CSV/JSON exports.
* Transfer larger exports back through the tunnel in controlled chunks only when explicitly requested.

Normal reporting requests return compact aggregates instead of moving full inventory datasets through the tunnel.

### Sonarr, Radarr, and Lidarr

The Arr integrations provide reporting and controlled administration:

* Lightweight connectivity and version status.
* Health warnings/errors.
* Queue, history, and command status.
* Root folder, profile, tag, and metadata-profile discovery.
* List/search movies, series, and artists.
* Add new movies, series, and artists.
* Update monitored state, quality profiles, root folders, tags, and applicable metadata profiles.
* Preview bulk quality selections before changing them.
* Run controlled bulk monitoring/profile/search workflows.
* Generate local CSV/JSON inventory exports.
* Report logical storage using the applications' own statistics.

New media additions deliberately require an explicit root folder and profile instead of guessing a storage path.

### Delete Safety

Arr deletion uses a two-stage workflow:

1. `arr_prepare_delete` returns the exact item/path, delete-files choice, and a short-lived confirmation token without deleting anything.
2. `arr_confirm_delete` can execute only with the prepared token and only after the exact deletion has been explicitly confirmed.

Physical media deletion is separately bound to the prepared `delete_files` choice.

ChatGPT app permission settings do not bypass these gateway-level safeguards.

## Self-Healing Tunnel

The installer creates a managed tunnel runner and a separate watchdog Scheduled Task.

The current recovery design deliberately distinguishes **liveness** from **readiness**:

* `/healthz` determines whether the local tunnel process is alive.
* `/readyz` reports whether the tunnel is currently ready to serve MCP requests.
* One transient readiness failure does **not** cause an immediate restart.
* Readiness-triggered recovery requires multiple consecutive failures.
* A restart cooldown prevents repeated restart storms.
* A startup grace period prevents a newly started tunnel from being killed before it has had time to initialize.

Default recovery policy:

| Setting | Default |
| --- | ---: |
| Consecutive readiness failures before recovery | 3 |
| Readiness restart cooldown | 10 minutes |
| Startup grace period | 90 seconds |
| Healthy watchdog heartbeat | 60 minutes |

These values can be changed in the local configuration file.

## Bounded Logging

The gateway intentionally avoids unlimited append-only runtime logs.

Default logging policy:

| Log | Default limit | Retained rotated files |
| --- | ---: | ---: |
| Tunnel runtime | 25 MB | 3 |
| Tunnel watchdog | 5 MB | 3 |
| Installer transcripts | Newest 10 | N/A |

Tunnel runtime output is normalized to UTF-8. If an older installation already has an extremely large runtime log, the updated runner keeps only a bounded recent tail rather than carrying the entire oversized file forward.

The installer writes timestamped transcripts under the managed `logs` directory. Logs may contain environment-sensitive diagnostic information and should be reviewed before being shared publicly.

All limits can be changed with the optional configuration settings shown below.

## Tunnel Health Endpoint and Local Admin UI

The tunnel client uses an ephemeral loopback port for its local health listener.

The currently assigned base address is stored in:

```text
tunnel-health-endpoint.txt
```

This is a **plain-text state file**, not a Windows Internet Shortcut. Older gateway versions used the misleading filename `tunnel-health.url`; the current installer migrates away from it.

The endpoint file can disappear briefly during a deliberate tunnel restart because the stale endpoint is removed before the new tunnel writes its current port.

The installer also creates:

```text
Open-Tunnel-UI.ps1
```

Run that helper locally on the Windows gateway server to read the current endpoint and open the tunnel client's `/ui` page without manually tracking the changing localhost port.

## Read-Only Tunnel Diagnostics

The current gateway includes bounded diagnostic tools intended for troubleshooting intermittent gateway errors without dumping an unlimited raw log through MCP:

* `plex_tunnel_delay_test` performs a controlled read-only delay so response/deadline boundaries can be measured.
* `plex_tunnel_runtime_diagnostics` summarizes recent runtime events such as restarts, response deadlines, transport failures, TTL-related messages, and 502/503/504 symptoms.

These diagnostic tools do not modify Plex media or metadata.

Generic automatic retry/TTL tuning is **not enabled by default**. A failed write can sometimes complete on the target even when its response is lost, so blindly repeating every write would risk duplicating an action. Read/verify/retry behavior should be implemented deliberately for the operation involved.

## Installer Console Status Colors

The installer uses status colors to make the console easier to scan:

* **Green**: successful or healthy status.
* **Yellow**: warnings.
* **Red**: errors.
* **Cyan**: informational/corrective actions.
* **Default/white**: neutral data and informational values, including the Installation Complete detail section.

## Requirements

* Windows Server with Windows PowerShell 5.1 or later.
* Administrator rights when running the installer.
* A provisioned OpenAI Secure MCP Tunnel and tunnel ID.
* An OpenAI runtime/control-plane API key authorized to use that tunnel.
* A working Plex Media Server and valid Plex authentication token.
* A working Tautulli instance and API key.
* Working Sonarr, Radarr, and Lidarr instances and API keys.
* Network connectivity from the Windows gateway host to the configured media APIs.
* Internet access during initial setup when required runtime components are not already cached.
* A ChatGPT plan/workspace with the MCP capabilities required for the actions you intend to use.

The current installer expects configuration values for Plex, Tautulli, Sonarr, Radarr, and Lidarr.

## What the Installer Downloads

You do **not** need to preinstall Python, the MCP Python SDK, PlexAPI, the OpenAI tunnel client, or Cloudflared for the normal installation path.

| Component | Purpose | Official source |
| --- | --- | --- |
| OpenAI Secure MCP Tunnel client | Connects the private MCP gateway to supported OpenAI products without exposing a public inbound endpoint. | [OpenAI tunnel-client releases](https://github.com/openai/tunnel-client/releases/latest) |
| OpenAI Secure MCP Tunnel documentation | Setup and troubleshooting documentation. | [Secure MCP Tunnels guide](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels) |
| CPython 3.12.10 | Application-local Python runtime managed by the installer. | [Python 3.12.10 on NuGet](https://www.nuget.org/packages/python/3.12.10) |
| MCP Python SDK | MCP server implementation. The installer installs `mcp[cli]>=2,<3`. | [mcp on PyPI](https://pypi.org/project/mcp/) |
| PlexAPI | Python bindings used to communicate with Plex Media Server. | [PlexAPI on PyPI](https://pypi.org/project/PlexAPI/) |

The full OpenAI tunnel-client archive may also include its supported Cloudflared companion. When present, the installer copies and manages that bundled executable.

## Configuration

Secrets and environment-specific addresses are stored in a separate local PowerShell data file rather than in the public installer.

1. Copy `MediaStack-Control-Gateway.config.example.psd1` to `MediaStack-Control-Gateway.config.psd1` in the same folder as the installer.
2. Replace every value beginning with `<REQUIRED:`.
3. Adjust optional values only when the defaults are unsuitable.
4. Run `Install-MediaStack-Control-Gateway.ps1` from an elevated Windows PowerShell session.

The real `MediaStack-Control-Gateway.config.psd1` file is excluded by `.gitignore` so it is not committed accidentally.

### Required Configuration Fields

| Field | Purpose |
| --- | --- |
| `TunnelId` | OpenAI tunnel ID assigned to this MCP connection. |
| `OpenAiRuntimeKey` | Runtime/control-plane API key used by the tunnel client. |
| `PlexUrl` | Plex Media Server base URL including port. |
| `PlexToken` | Plex authentication token. |
| `TautulliUrl` | Tautulli base URL including port. |
| `TautulliApiKey` | Tautulli API key. |
| `SonarrUrl` | Sonarr base URL including port. |
| `SonarrApiKey` | Sonarr API key. |
| `RadarrUrl` | Radarr base URL including port. |
| `RadarrApiKey` | Radarr API key. |
| `LidarrUrl` | Lidarr base URL including port. |
| `LidarrApiKey` | Lidarr API key. |

### Optional Configuration Fields

| Field | Default | Purpose |
| --- | ---: | --- |
| `InstallRoot` | `C:\Scripts\MediaStack-Control-Gateway` | Managed installation directory. |
| `RuntimeLogMaxMB` | `25` | Maximum active tunnel runtime log size before rotation. |
| `RuntimeLogRetainedFiles` | `3` | Number of rotated runtime logs retained. |
| `WatchdogLogMaxMB` | `5` | Maximum active watchdog log size before rotation. |
| `WatchdogLogRetainedFiles` | `3` | Number of rotated watchdog logs retained. |
| `InstallerLogRetainCount` | `10` | Number of timestamped installer transcripts retained. |
| `WatchdogReadinessFailureThreshold` | `3` | Consecutive readiness failures before readiness-triggered recovery. |
| `WatchdogReadinessRestartCooldownMinutes` | `10` | Minimum time between readiness-triggered restarts. |
| `WatchdogStartupGraceSeconds` | `90` | Grace period after tunnel start. |
| `WatchdogHealthyHeartbeatMinutes` | `60` | Frequency of healthy watchdog heartbeat entries. |

Optional numeric values must be positive integers.

## Installation

After creating the local configuration file, open Windows PowerShell as Administrator and run:

```powershell
.\Install-MediaStack-Control-Gateway.ps1
```

The installer is idempotent. Working stages report `SKIP`; missing, stale, or changed managed components are repaired or updated.

The installer validates Plex, Tautulli, Sonarr, Radarr, and Lidarr, validates the generated MCP server, validates the tunnel profile with `tunnel-client doctor`, starts or reuses the managed runtime, and performs final `/healthz` and `/readyz` checks.

## ChatGPT App Setup

With the installer complete and the tunnel healthy:

1. Enable Developer Mode according to the current OpenAI instructions for your workspace.
2. Create a custom MCP app in ChatGPT.
3. Choose **Tunnel** as the connection method.
4. Select or enter the same tunnel ID used by the gateway configuration.
5. Scan/discover the available actions.
6. Begin with read-only tests before using write actions.

Suggested initial tests:

```text
Check Plex status and show my libraries. Do not make any changes.
```

```text
Check Plex, Tautulli, Sonarr, Radarr, and Lidarr connectivity. Do not make any changes.
```

When gateway updates add or change MCP actions, ChatGPT does not necessarily apply those changes automatically. Refresh/review the app actions in Workspace Settings according to the current OpenAI app-management workflow. Depending on plan and whether the app has already been published, recreating or republishing the custom app may be required.

## Recommended ChatGPT Configuration

### App Permissions

This gateway exposes both read and write operations. Depending on ChatGPT app permission settings, ChatGPT may ask for approval before running a command, particularly when a write action is used for the first time.

For an administrator-controlled personal Plex environment, a user may choose to configure the MediaStack Control Gateway app to **Allow all actions**. This can prevent routine gateway commands from waiting for an approval prompt.

Enable that permission only when you understand and trust the actions exposed by the gateway. It is an elevated-access setting.

Changing the ChatGPT app permission does **not** grant additional capabilities to the gateway. It controls whether ChatGPT asks before invoking capabilities that the gateway already exposes. Gateway-level safeguards remain in effect; for example, Arr deletion still uses its prepare-and-confirm workflow.

UI names and permission options may change, so use the current ChatGPT app permission controls shown for your workspace.

### Recommended ChatGPT Memory

The gateway does not require ChatGPT Memory, but remembering a few conventions can make future sessions more predictable.

The following text can be pasted into a ChatGPT conversation and requested to be remembered:

```text
Remember these conventions for my MediaStack Control Gateway:

When I say "touch" a Plex movie, television show, season, episode, collection, actor's media, director's media, or other selection, interpret "touch" as changing only the selected Plex items' addedAt metadata so they appear in Recently Added. Do not move, delete, rename, rematch, re-download, or modify the underlying media files.

After every Touch operation, automatically run the non-destructive Plex library hub refresh for each affected library and verify the resulting Recently Added ordering. Do not ask separately whether the hub refresh should be performed.

Treat explicitly requested normal Plex metadata edits and collection membership changes as ordinary non-delete writes. Never infer permission to delete media. Arr deletion must continue to use the gateway's prepare-and-confirm safety process.

When a write returns a gateway or transport error, do not automatically assume that the target change failed. Verify the resulting Plex or Arr state before retrying, because the action may have completed even if its response was lost.

When reporting Plex actions, distinguish between changes confirmed by the Plex server and display behavior that may still be affected by an individual Plex client's local cache.
```

Individual MCP function names do not need to be stored in Memory. ChatGPT discovers the current tool schema from the app itself.

## Security Notes

* Keep the real `MediaStack-Control-Gateway.config.psd1` private.
* Do not commit tokens, API keys, tunnel IDs, internal addresses, usernames, or environment-specific exports/logs to a public repository.
* The installer applies restricted Windows ACLs to the local configuration and generated files that can contain credentials.
* Logs, reporting exports, screenshots, and command output may reveal information about the local environment and should be reviewed before sharing.
* Only connect ChatGPT to MCP servers you trust and understand.
* App-level approval settings do not replace application-level safety controls.

## Updating

The installer is intentionally safe to run repeatedly. Replace the public installer with the newer version and run it again from the same folder as the existing local configuration file.

The installer compares generated content, updates only managed components that changed, and restarts the tunnel when the MCP schema actually changes.

After an update that changes tools, refresh/review the custom app actions in ChatGPT so its approved schema matches the live gateway.

## Attribution and AI Assistance

Some portions of this project may be adaptations of, inspired by, or derived from publicly available examples, documentation, community discussions, or other prior work. AI tools may also have been used to help create, review, troubleshoot, document, format, or refine code.

Specific third party sources or license requirements are identified in the relevant file or documentation when applicable. Third party software and APIs used by the project, including OpenAI's tunnel client, Python, the Model Context Protocol Python SDK, Plex/PlexAPI, Tautulli, Sonarr, Radarr, and Lidarr, remain subject to their own licenses and terms.

## License

This repository is provided under the MIT License. See [`LICENSE`](./LICENSE) for the applicable terms and warranty disclaimer.
