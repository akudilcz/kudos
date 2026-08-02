# The compile factory's toolchain, pinned.
#
# kudos carries no compiler (spec ARCH-012): the in-kudos agent generates Zig
# source and POSTs it to factory.py, which compiles it off-target into a .kudos
# module. The compiler that produces those modules is part of the contract — the
# kernel executes its output sight unseen after ABI verification — so it is
# pinned here to the exact zig the rest of the repo builds with (the version and
# checksum come from scripts/setup.sh, the pin's one home, via factory-setup.sh).
#
# Build it with `make factory-setup`; run it with `make factory`.

# Pinned by digest, not by tag: a toolchain that drifts under a running agent is
# the bug this image exists to prevent.
FROM debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818

ARG ZIG_VERSION
ARG ZIG_SHA256

ENV DEBIAN_FRONTEND=noninteractive

# python3 runs factory.py; binutils is readelf, which the factory's
# position-independence and image-size checks shell out to.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 binutils curl xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/zig.tar.xz \
        "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz

ENV ZIG=/opt/zig/zig

# The repo is mounted here read-only at run time; nothing of kudos is baked in.
WORKDIR /kudos
