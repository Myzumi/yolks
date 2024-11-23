FROM        --platform=$TARGETOS/$TARGETARCH node:20-bullseye-slim

LABEL       author="Myzumi Myzunto" maintainer="private@no.de"

RUN         apt update \
            && apt -y install ffmpeg iproute2 git sqlite3 libsqlite3-dev python3 python3-dev ca-certificates dnsutils tzdata zip tar curl build-essential libtool iputils-ping libnss3 tini default-jre \
            && useradd -m -d /home/container container

RUN         npm install npm@latest typescript ts-node @types/node --location=global

# install pnpm
RUN         npm install -g corepack
RUN         corepack enable
RUN         corepack prepare pnpm@latest --activate

USER        container
ENV         USER=container HOME=/home/container
WORKDIR     /home/container

# Setup JAVA_HOME -- useful for docker commandline
ENV 		JAVA_HOME /usr/lib/jvm/java-8-openjdk-amd64/
RUN 		export JAVA_HOME

COPY        ./../entrypoint.sh /entrypoint.sh
CMD         [ "/bin/bash", "/entrypoint.sh" ]
