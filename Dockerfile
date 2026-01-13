
# This is a fork from phyremaster/papermc
# V1.0.1 fixes PaperMC api path
# V1.0.2 fixed MC_RAM_MIN not reading properly
# V1.0.3 Changed openjdk from 12 to 23
# V1.0.4 Changed openjdk from 23 to 25 and fixed PaperMC API endpoint (v2 => v3)

# Added udev-lib for OSHI

FROM alpine:latest

# Environment variables
ENV MC_VERSION="latest" \
    PAPER_BUILD="latest" \
    EULA="false" \
    MC_RAM="" \
    JAVA_OPTS=""

COPY ./paper.sh .
RUN apk update
RUN apk add libstdc++
RUN apk add openjdk25-jre
RUN apk add bash
RUN apk add curl
RUN apk add jq
RUN apk add eudev udev-init-scripts
RUN apk add openrc 
RUN rc-update add udev sysinit
RUN rc-update add udev-trigger sysinit
RUN rc-update add udev-settle sysinit
RUN rc-update add udev-postmount default
RUN mkdir /papermc


CMD ["bash", "./paper.sh"]


EXPOSE 25565/tcp
VOLUME /papermc
