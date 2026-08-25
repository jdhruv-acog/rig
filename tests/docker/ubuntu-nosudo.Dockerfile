# The same Ubuntu with no way to become root at all: sudo is purged and its
# binary removed, so any attempt to escalate fails loudly rather than silently
# succeeding through a leftover setuid file.
#
# git is pre-installed, because that is the real question this image asks: with
# the one thing rig cannot install itself already present, can a person with no
# administrator rights get the whole toolchain?
FROM ubuntu:24.04

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl tar unzip git \
 && DEBIAN_FRONTEND=noninteractive apt-get purge -y sudo \
 && rm -f /usr/bin/sudo /usr/lib/sudo/sudoers.so \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash rigtest

USER rigtest
WORKDIR /home/rigtest
ENV HOME=/home/rigtest SHELL=/bin/bash
