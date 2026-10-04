# Tor transparent-proxy container for MikroTik RouterOS containers.
#
# DUAL-ARCH BUILD (mirrors ../tailscale-mikrotik):
#   arm32v5 (soft-float)  — hAP ax S / hEX Refresh (MediaTek EN7562CT). The
#                           container runtime SIGILLs on ARMv7/hard-float, so
#                           the runtime base must be a soft-float arm32v5 port.
#   arm64   (ARMv8)        — RB5009 (Cortex-A72) and other aarch64 boards.
#
# Unlike the tailscale image we do NOT cross-compile anything: Tor is installed
# from the Debian package archive for the target arch, so the whole build runs
# under the target-arch base image (via QEMU when cross-building). Debian's
# arm32v5 port is soft-float and compatible with the EN7562CT runtime — the
# same base the working tailscale arm32 image uses.
#
# Build arg (default keeps arm32v5 behaviour so a bare `docker build` works):
#   RUNTIME_BASE   arm32v5/debian:bookworm-slim | arm64v8/debian:bookworm-slim

ARG RUNTIME_BASE=arm32v5/debian:bookworm-slim
FROM ${RUNTIME_BASE}

# tor            — the daemon itself (Debian ships a client-capable build)
# iptables/iproute2 — present for parity/debugging inside the container; the
#                  actual transparent redirect is done on the RouterOS host, not
#                  here, but these help when inspecting flows.
# openssh-server — management access, same pattern as the tailscale container.
# ca-certificates/curl/jq/bash — utilities for debugging and scripts.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      tor ca-certificates iptables iproute2 bash openssh-server curl jq && \
    rm -rf /var/lib/apt/lists/*

# Use iptables-legacy for compatibility with the container runtime (same as the
# tailscale image).
RUN update-alternatives --set iptables /usr/sbin/iptables-legacy || true; \
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true

# SSH host keys are generated at container startup (see tor.sh), not build time
# — RSA keygen under arm/v5 QEMU emulation is unreliable and per-container keys
# are better practice.
RUN mkdir -p /var/run/sshd

# Tor data dir owned by the packaged unprivileged user.
RUN mkdir -p /var/lib/tor && chown -R debian-tor:debian-tor /var/lib/tor

COPY torrc /etc/tor/torrc
COPY sshd_config /etc/ssh/
COPY tor.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/tor.sh

# 22   management SSH
# 9040 TransPort (transparent TCP)   9053 DNSPort   9050 SOCKS
EXPOSE 22 9040 9050 9053
CMD ["/usr/local/bin/tor.sh"]
