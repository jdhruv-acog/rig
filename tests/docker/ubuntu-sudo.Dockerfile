# A stock Ubuntu with an ordinary account that can borrow root.
#
# git is deliberately absent: this is the image that exercises rig's one
# package-manager path, `sudo apt-get install -y git`. curl, tar and unzip are
# present because rig refuses without them, and that refusal has its own image.
FROM ubuntu:24.04

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl tar unzip sudo \
 && rm -rf /var/lib/apt/lists/*

# rig runs as a person, never as root. Root can write anywhere, so it would hide
# exactly the permission mistakes this matrix exists to catch.
RUN useradd --create-home --shell /bin/bash rigtest \
 && printf 'rigtest ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/rigtest \
 && chmod 0440 /etc/sudoers.d/rigtest

USER rigtest
WORKDIR /home/rigtest
ENV HOME=/home/rigtest SHELL=/bin/bash
