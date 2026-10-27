FROM alpine:3.23

LABEL org.opencontainers.image.title="PaperMC Docker" \
      org.opencontainers.image.source="https://github.com/OeschMe/papermc" \
      org.opencontainers.image.version="1.2.0"

ENV MC_VERSION="latest" \
    PAPER_BUILD="latest" \
    PAPER_CHANNEL="STABLE" \
    PAPER_PROJECT="paper" \
    EULA="false" \
    MC_RAM="" \
    MC_RAM_MIN="" \
    JAVA_OPTS="" \
    PAPER_UA="oeschme-papermc/1.2.0 (https://github.com/OeschMe/papermc)" \
    PAPER_DATA_DIR="/papermc" \
    PAPER_OFFLINE="false"

RUN apk add --no-cache bash ca-certificates curl jq libstdc++ openjdk25-jre eudev-libs flock \
    && mkdir -p /papermc
COPY --chmod=755 paper.sh /paper.sh

EXPOSE 25565/tcp
VOLUME ["/papermc"]
STOPSIGNAL SIGTERM
CMD ["bash", "/paper.sh"]
