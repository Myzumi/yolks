# Space Engineers Quasar + Magnetar Pterodactyl runtime.
#
# Transitional image: deliberately keeps the fork-owned Myzumi Wine yolk
# as the base so we retain its user/runtime/SteamCMD plumbing while Quasar runs the
# SE dedicated server natively through MagnetarInterim (.NET 10). Wine is present
# but is not used by the Quasar/Magnetar launch path.
FROM ghcr.io/myzumi/yolks:wine_latest

LABEL org.opencontainers.image.title="Space Engineers Quasar Pterodactyl Yolk"
LABEL org.opencontainers.image.description="Quasar + MagnetarInterim runtime for Space Engineers Dedicated Server"
LABEL org.opencontainers.image.source="https://github.com/Myzumi/yolks"

USER root

# Quasar itself only needs the ASP.NET runtime, but the SDK is useful for QuasarHub
# source-built UI plugins. Install .NET 10 in an image-owned location so Quasar's
# installer never needs sudo/systemd inside the Pterodactyl container.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl gzip jq procps python3 tar util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && bash /tmp/dotnet-install.sh --channel 10.0 --quality GA --install-dir /usr/share/dotnet \
    && ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet \
    && rm -f /tmp/dotnet-install.sh

ENV DOTNET_ROOT=/usr/share/dotnet
ENV PATH="/usr/share/dotnet:${PATH}"

COPY entrypoint.sh /entrypoint.sh
COPY se_collection_sync.py /usr/local/bin/se-collection-sync-legacy

RUN chmod 0755 /entrypoint.sh /usr/local/bin/se-collection-sync-legacy

CMD ["/bin/bash", "/entrypoint.sh"]
