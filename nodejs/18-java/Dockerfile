FROM        --platform=$TARGETOS/$TARGETARCH node:18-bookworm-slim

LABEL       author="Myzumi Myzunto" maintainer="private@no.de"

RUN         apt update \
            && apt -y install ffmpeg iproute2 git sqlite3 libsqlite3-dev python3 python3-dev ca-certificates dnsutils tzdata zip tar curl build-essential libtool tini default-jre \
            && npm -g install npm@latest \
            && useradd -m -d /home/container container

RUN         npm install npm@9.8.1 typescript ts-node @types/node --location=global

USER        container
ENV         USER=container HOME=/home/container
WORKDIR     /home/container

STOPSIGNAL SIGINT
# Setup JAVA_HOME -- useful for docker commandline
ENV 		JAVA_HOME /usr/lib/jvm/java-8-openjdk-amd64/
RUN 		export JAVA_HOME

COPY        ./../entrypoint.sh /entrypoint.sh
CMD         [ "/bin/bash", "/entrypoint.sh" ]

COPY        --chown=container:container ./../entrypoint.sh /entrypoint.sh
RUN         chmod +x /entrypoint.sh
ENTRYPOINT    ["/usr/bin/tini", "-g", "--"]
CMD         ["/entrypoint.sh"]
