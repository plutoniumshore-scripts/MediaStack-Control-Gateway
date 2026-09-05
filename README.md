# MediaStack Control Gateway

MediaStack Control Gateway is a Windows Server based MCP gateway for people who run a self hosted Plex media environment and want one controlled interface for visibility, reporting, and administration across Plex, Tautulli, Sonarr, Radarr, and Lidarr.

The project began as a Plex focused MCP integration, but it now acts as a broader media operations layer. It installs and maintains a local MCP server, connects it to ChatGPT through OpenAI Secure MCP Tunnel, exposes reporting and management tools for the supported media applications, and creates Windows Scheduled Tasks that keep the tunnel available and automatically recover it if it becomes unhealthy.

**If you find anything here useful, please consider donating:**

https://paypal.me/plutoniumshore

## Intended Deployment

**The gateway is intended to run natively on Windows Server. It is not designed as a Docker or container deployment.**

The installer uses Windows PowerShell, Windows Scheduled Tasks, Windows ACLs, and Windows filesystem paths. The gateway host should therefore be a Windows Server system where the installer can run with Administrator privileges.

Plex, Tautulli, Sonarr, Radarr, and Lidarr do not need to run on the gateway server. They may be hosted on other computers or platforms as long as the Windows Server running MediaStack Control Gateway can reach their HTTP APIs. The restriction against Docker or containers applies to the **gateway deployment itself**, not to the media applications it connects to.

This project assumes that the Plex, Tautulli, Sonarr, Radarr, and Lidarr environment already exists and is working. Installation and configuration of those applications is outside the scope of this repository.

## Who This Is For

This project is most useful for home lab users, Plex administrators, and self hosted media enthusiasts who already run Plex, Tautulli, Sonarr, Radarr, and Lidarr and want to query or manage that environment through ChatGPT and MCP without manually moving between each application's web interface.

It is particularly useful when the media applications are spread across multiple systems. The gateway only needs network access to each application's HTTP API.

## What It Does

### Plex

The gateway provides tools to:

* Check Plex server status and enumerate libraries.
* Search library content.
* List, inspect, create, rename, update, and delete Plex collections.
* Add, remove, or replace collection members.
* Create and modify smart collections and their filters.
* Read and update collection summaries, labels, visibility, sort/display settings, posters, and background art.
* Read and update individual movie and TV show summaries by exact Plex rating key while preserving other item metadata.
* Search TV shows and episodes.
* Create narrowly scoped TV playlists.

Plex collection operations do not delete the underlying media files.

### Tautulli Reporting

Tautulli is used as a reporting and analytics source. The gateway can:

* Check reporting connectivity and verify the Plex server identity.
* Report library counts, media breakdowns, and logical storage usage.
* Return largest items, watch history, and top statistics.
* Generate larger CSV or JSON inventory exports locally.
* Read large exports back in controlled chunks instead of sending an entire dataset through the tunnel unnecessarily.

### Sonarr, Radarr, and Lidarr

The Arr integrations support both reporting and controlled management, including:

* Connectivity, health, queue, history, command status, and storage reporting.
* Listing and searching movies, series, and artists.
* Adding new movies, series, and artists with explicitly selected root folders and profiles.
* Updating monitoring state, quality profiles, metadata profiles where applicable, root folders, and tags.
* Bulk quality changes with preview capability.
* Bulk monitoring and search workflows.
* Local CSV or JSON inventory exports.

New media additions require explicit root folder and profile choices. The gateway does not guess storage locations.

### Delete Safety

Arr deletions use a two step confirmation workflow. A deletion is first prepared and returned with a short lived confirmation token. The destructive operation can only proceed using that prepared token after the exact deletion has been explicitly confirmed, including whether managed media files should also be removed.

### Self Healing Tunnel

The installer configures the OpenAI tunnel client and creates Windows Scheduled Tasks that:

* Start the gateway tunnel at system startup.
* Restart the tunnel when necessary.
* Check tunnel health on a recurring basis.
* Repair or restart an unhealthy tunnel automatically.

The installer is designed to be idempotent, so it can be run again to repair or update the managed installation. Existing working components are reused where possible.

## Requirements

* Windows Server with Windows PowerShell 5.1 or later.
* Administrator rights when running the installer.
* An existing, working environment containing Plex, Tautulli, Sonarr, Radarr, and Lidarr. The current installer expects configuration values for all five services.
* Network connectivity from the Windows gateway server to the HTTP APIs of the media applications being used.
* A provisioned OpenAI Secure MCP Tunnel and its tunnel ID.
* An OpenAI runtime API key with permission to use the tunnel.
* Valid API credentials for the media applications being connected.
* Internet access during initial setup so the installer can retrieve required runtime components when they are not already cached locally.
* A ChatGPT plan/workspace that supports the MCP capabilities you intend to use. Full MCP write and modify actions are currently available to supported Business, Enterprise, and Edu workspaces. Check the current OpenAI documentation because availability and UI labels can change.

## What the Installer Downloads

You do **not** need to preinstall Python, the MCP Python SDK, PlexAPI, the OpenAI tunnel client, or Cloudflared for the normal installation path. The installer retrieves and manages the components it needs.

The following links are provided both for transparency and for manual troubleshooting if an automatic download is unavailable.

| Component | How it is used | Official source |
| --- | --- | --- |
| OpenAI Secure MCP Tunnel client | Connects the private Windows hosted MCP gateway to ChatGPT without requiring a public inbound endpoint. The installer downloads the current full Windows release. | [OpenAI tunnel-client releases](https://github.com/openai/tunnel-client/releases/latest) |
| OpenAI Secure MCP Tunnel documentation | Official setup, permissions, architecture, and troubleshooting documentation. | [Secure MCP Tunnels guide](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels) |
| CPython 3.12.10 | Application local Python runtime managed by the installer. | [Python 3.12.10 on NuGet](https://www.nuget.org/packages/python/3.12.10) |
| MCP Python SDK | Provides the MCP server implementation used by the generated gateway. The installer installs `mcp[cli]>=2,<3`. | [mcp on PyPI](https://pypi.org/project/mcp/) |
| PlexAPI | Python bindings used to communicate with Plex Media Server. | [PlexAPI on PyPI](https://pypi.org/project/PlexAPI/) |

The full OpenAI tunnel client archive may also contain its supported Cloudflared companion. When present, the installer copies and manages that bundled executable rather than requiring a separate Cloudflared installation.

## OpenAI and ChatGPT Configuration

The media application APIs are only one side of the setup. ChatGPT also has to be authorized to reach the local MCP gateway through an OpenAI Secure MCP Tunnel.

The current OpenAI tunnel documentation is available here:

* [OpenAI Secure MCP Tunnel guide](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)
* [OpenAI tunnel-client project and documentation](https://github.com/openai/tunnel-client)
* [OpenAI tunnel management](https://platform.openai.com/settings/organization/tunnels)
* [OpenAI runtime API keys](https://platform.openai.com/settings/organization/api-keys)
* [OpenAI organization roles](https://platform.openai.com/settings/organization/people/roles)
* [OpenAI organization groups](https://platform.openai.com/settings/organization/people/groups)
* [ChatGPT connector/app settings](https://chatgpt.com/#settings/Connectors)
* [ChatGPT Developer Mode and MCP apps](https://help.openai.com/en/articles/12584461-developer-mode-and-full-mcp-connectors-in-chatgpt-beta)

### 1. Create or Select an OpenAI Tunnel

Open [OpenAI tunnel management](https://platform.openai.com/settings/organization/tunnels) and create a tunnel for the ChatGPT workspace that will use MediaStack Control Gateway, or select an existing tunnel intended for this gateway.

Record the resulting tunnel ID. It should have the form:

```text
tunnel_0123456789abcdef0123456789abcdef
```

The tunnel must be associated with the correct ChatGPT workspace. A tunnel can exist in the OpenAI Platform but still fail to appear in ChatGPT if it was created for the wrong workspace or the user does not have the required permissions.

### 2. Configure Tunnel Permissions

The account or principal used by the long running gateway needs Tunnels **Read** and **Use** permissions.

Users who create or modify tunnels also need Tunnels **Manage** permission.

OpenAI provides the relevant controls under:

* [Organization roles](https://platform.openai.com/settings/organization/people/roles)
* [Organization groups](https://platform.openai.com/settings/organization/people/groups)

For a normal gateway runtime, use only the permissions required to operate the tunnel rather than broad administrative access.

### 3. Create a Runtime API Key

Open [OpenAI runtime API keys](https://platform.openai.com/settings/organization/api-keys) and create a runtime key for the tunnel client.

Where the UI allows permission restriction, grant the runtime key Tunnels **Read** and **Use**.

Do not substitute an OpenAI Admin API key for the long running gateway. Admin keys are intended for administrative tunnel operations, not for the tunnel daemon itself.

Place the runtime key in the local configuration file as `OpenAiRuntimeKey`.

### 4. Add the Tunnel Values to the Gateway Configuration

The two OpenAI values required by the installer are:

| Configuration field | Source |
| --- | --- |
| `TunnelId` | The tunnel created or selected in OpenAI tunnel management. |
| `OpenAiRuntimeKey` | The restricted runtime API key created for the tunnel client. |

After these and the media API fields are populated, run the installer from an elevated PowerShell session.

The installer creates the tunnel profile, validates it with `tunnel-client doctor`, starts the managed runtime, and creates Windows Scheduled Tasks to keep it running.

### 5. Verify the Tunnel Is Ready

Complete the installer before creating or testing the ChatGPT app. The tunnel runtime needs to be healthy for ChatGPT to discover and call the MCP tools.

The installer performs its own validation and configures a local health listener. A successful installation should report that the tunnel is ready and that the supported media APIs can be reached.

OpenAI tunnel-client exposes local health and readiness endpoints on the Windows gateway server. These loopback endpoints are for local diagnostics and are not public URLs.

### 6. Enable ChatGPT Developer Mode if Required

Custom MCP apps require Developer Mode in supported ChatGPT configurations.

Current OpenAI documentation describes the controls under ChatGPT or Workspace settings. Depending on the plan and workspace role, an administrator or owner may first need to enable the ability to create custom MCP apps.

Use the current instructions here:

[Developer Mode and MCP apps in ChatGPT](https://help.openai.com/en/articles/12584461-developer-mode-and-full-mcp-connectors-in-chatgpt-beta)

Because OpenAI changes product navigation periodically, use the current documentation rather than relying solely on screenshots or old menu names.

### 7. Create the ChatGPT App/Connector

With the gateway tunnel running and healthy:

1. Open [ChatGPT connector/app settings](https://chatgpt.com/#settings/Connectors).
2. Create a custom MCP app/connector.
3. Choose **Tunnel** as the connection type when that option is presented.
4. Select the same tunnel created for MediaStack Control Gateway, or paste its `tunnel_id` if the UI requests it.
5. Scan/discover the MCP tools and verify that the MediaStack Control Gateway tools appear.
6. Complete creation of the app/connector.
7. Enable or publish it according to the rules of your ChatGPT workspace.

The Windows tunnel runtime must remain available for initial tool discovery and for every later MCP request. The Scheduled Tasks created by this installer are intended to provide that persistence automatically.

### 8. Test from ChatGPT

Start a new ChatGPT conversation with the MediaStack Control Gateway app enabled and begin with read only requests, for example:

```text
Check Plex status and show my libraries. Do not make any changes.
```

```text
Check connectivity to Plex, Tautulli, Sonarr, Radarr, and Lidarr. Do not make any changes.
```

Once read operations have been verified, test narrowly scoped management operations before attempting bulk changes.

If a future gateway update adds or changes MCP tools, ChatGPT may require the custom app's tools/actions to be rescanned or refreshed before the new definitions are available.

## Configuration

Secrets and private environment information are stored in a separate local configuration file rather than in the installer.

1. Copy `MediaStack-Control-Gateway.config.example.psd1` to `MediaStack-Control-Gateway.config.psd1` in the same folder as the installer.
2. Replace every value beginning with `<REQUIRED:`.
3. Leave `InstallRoot` at its default unless you want the gateway installed somewhere else.
4. Run `Install-MediaStack-Control-Gateway.ps1` from an elevated PowerShell session.

The local `MediaStack-Control-Gateway.config.psd1` file is excluded by `.gitignore` so credentials are not added to source control by default.

### Required Configuration Fields

| Field | What to enter |
| --- | --- |
| `TunnelId` | The OpenAI tunnel ID assigned to this MCP connection. |
| `OpenAiRuntimeKey` | The runtime/control plane API key used by the OpenAI tunnel client. |
| `PlexUrl` | The base URL of the Plex Media Server API, including its port. |
| `PlexToken` | A valid Plex authentication token. |
| `TautulliUrl` | The base URL of the Tautulli API, including its port. |
| `TautulliApiKey` | The Tautulli API key. |
| `SonarrUrl` | The base URL of Sonarr, including its port. |
| `SonarrApiKey` | The Sonarr API key. |
| `RadarrUrl` | The base URL of Radarr, including its port. |
| `RadarrApiKey` | The Radarr API key. |
| `LidarrUrl` | The base URL of Lidarr, including its port. |
| `LidarrApiKey` | The Lidarr API key. |

The current installer expects all of the fields above to be populated. This repository assumes those services already exist and does not provide installation or configuration instructions for Plex, Tautulli, Sonarr, Radarr, or Lidarr.

### Optional Configuration Fields

| Field | Default | Purpose |
| --- | --- | --- |
| `InstallRoot` | `C:\Scripts\MediaStack-Control-Gateway` | Local working directory used for the managed gateway installation. |

## Installation

After creating and filling in the local configuration file, open PowerShell as Administrator and run:

```powershell
.\Install-MediaStack-Control-Gateway.ps1
```

The installer validates the configuration before proceeding. Placeholder values are detected and cause the installer to stop with the name of the field that still needs to be configured.

By default, managed runtime files, logs, profiles, exports, the portable Python environment, and generated gateway files are stored under:

```text
C:\Scripts\MediaStack-Control-Gateway
```

## Security Notes

Runtime credentials should be stored only in the local `MediaStack-Control-Gateway.config.psd1` file. That file is excluded by `.gitignore` and should not be placed in source control or shared publicly.

The installer applies restricted Windows ACLs to the local configuration and generated files that can contain credentials. Reporting exports, logs, screenshots, and command output may also contain information about the local media environment and should be reviewed before being shared.

## Attribution and AI Assistance

Some portions of this project may be adaptations of, inspired by, or derived from publicly available examples, documentation, community discussions, or other prior work. AI tools may also have been used to help create, review, troubleshoot, document, format, or refine code.

Specific third party sources or license requirements are identified in the relevant file or documentation when applicable. Third party software and APIs used by the project, including OpenAI's tunnel client, Python, the Model Context Protocol Python SDK, Plex/PlexAPI, Tautulli, Sonarr, Radarr, and Lidarr, remain subject to their own licenses and terms.

## License

This repository is provided under the MIT License. See [`LICENSE`](./LICENSE) for the applicable terms and warranty disclaimer.
