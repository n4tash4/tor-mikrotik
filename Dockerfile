ARG RUNTIME_BASE=arm32v5/debian:bookworm-slim
FROM ${RUNTIME_BASE}

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      tor ca-certificates iptables iproute2 bash openssh-server curl jq && \
    rm -rf /var/lib/apt/lists/* && \
    rm -f /etc/ssh/ssh_host_*

RUN update-alternatives --set iptables /usr/sbin/iptables-legacy || true; \
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true

RUN mkdir -p /var/run/sshd

RUN mkdir -p /var/lib/tor && chown -R debian-tor:debian-tor /var/lib/tor

COPY torrc /etc/tor/torrc
COPY sshd_config /etc/ssh/
COPY tor.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/tor.sh

EXPOSE 22 9040 9050 9053
CMD ["/usr/local/bin/tor.sh"]
