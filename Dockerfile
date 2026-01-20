
# This is a fork from phyremaster/papermc
# V1.0.1 fixes PaperMC api path
# V1.0.2 fixed MC_RAM_MIN not reading properly
# V1.0.3 Changed openjdk from 12 to 23
# V1.0.4 Changed openjdk from 23 to 25 and fixed PaperMC API endpoint (v2 => v3)
# V1.1.0 Rewrote the paper.sh
# V1.1.1 Fixing the OSHI errors

FROM alpine:latest

ENV MC_VERSION="latest" \
    PAPER_BUILD="latest" \
    EULA="false" \
    MC_RAM="" \
    JAVA_OPTS="" \
    PAPER_UA=""

COPY ./paper.sh .

RUN apk add --no-cache \
    bash curl jq \
    libstdc++ \
    openjdk25-jre \
    eudev-libs

RUN mkdir /papermc

EXPOSE 25565/tcp
VOLUME /papermc

CMD ["bash", "./paper.sh"]