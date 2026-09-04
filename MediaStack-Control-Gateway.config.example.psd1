@{
    # REQUIRED. OpenAI tunnel ID assigned to this MCP connection.
    TunnelId = '<REQUIRED: tunnel_...>'

    # REQUIRED. Runtime/control-plane API key used by the OpenAI tunnel client.
    OpenAiRuntimeKey = '<REQUIRED: OpenAI tunnel runtime API key>'

    # REQUIRED. Base URL and authentication token for Plex Media Server.
    PlexUrl = '<REQUIRED: http://PLEX-SERVER:32400>'
    PlexToken = '<REQUIRED: Plex authentication token>'

    # REQUIRED. Base URL and API key for Tautulli.
    TautulliUrl = '<REQUIRED: http://TAUTULLI-SERVER:8181>'
    TautulliApiKey = '<REQUIRED: Tautulli API key>'

    # REQUIRED. Base URLs and API keys for the Arr applications.
    SonarrUrl = '<REQUIRED: http://SONARR-SERVER:8989>'
    SonarrApiKey = '<REQUIRED: Sonarr API key>'

    RadarrUrl = '<REQUIRED: http://RADARR-SERVER:7878>'
    RadarrApiKey = '<REQUIRED: Radarr API key>'

    LidarrUrl = '<REQUIRED: http://LIDARR-SERVER:8686>'
    LidarrApiKey = '<REQUIRED: Lidarr API key>'

    # OPTIONAL. Change this only if you do not want the default install location.
    InstallRoot = 'C:\Scripts\MediaStack-Control-Gateway'
}
