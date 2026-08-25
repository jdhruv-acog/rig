# A Debian with git but without curl or unzip — the machine rig must refuse.
#
# The build asserts the absence rather than assuming it: a base image that
# starts shipping curl would turn this case into a silent pass.
FROM debian:12-slim

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /usr/bin/curl /usr/bin/unzip \
 && ! command -v curl >/dev/null 2>&1 \
 && ! command -v unzip >/dev/null 2>&1 \
 && command -v git >/dev/null 2>&1

RUN useradd --create-home --shell /bin/bash rigtest

USER rigtest
WORKDIR /home/rigtest
ENV HOME=/home/rigtest SHELL=/bin/bash
