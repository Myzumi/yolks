# Space Engineers-specific Pterodactyl runtime.
# Keeps the normal Pelican/Pterodactyl Wine runtime, but adds:
#   - idempotent Winetricks/Wine component setup
#   - correct VALIDATE=0 handling
#   - Steam Workshop collection -> Space Engineers Mods synchronization

FROM ghcr.io/myzumi/yolks:wine_latest

LABEL org.opencontainers.image.title="Space Engineers Pterodactyl Yolk"
LABEL org.opencontainers.image.description="Wine runtime with Space Engineers Workshop collection synchronization"
LABEL org.opencontainers.image.source="https://github.com/Myzumi/yolks"

COPY se_collection_sync.py /usr/local/bin/se-collection-sync
COPY entrypoint.sh /entrypoint.sh

RUN chmod 0755 /usr/local/bin/se-collection-sync /entrypoint.sh

CMD ["/bin/bash", "/entrypoint.sh"]
