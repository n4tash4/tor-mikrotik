# Tor for MikroTik Container (transparent proxy)

Build and configuration to run [Tor](https://www.torproject.org/) inside a
[MikroTik Container](https://help.mikrotik.com/docs/display/ROS/Container) as a
**transparent proxy**, so LAN clients can reach `.onion` services (and,
optionally, route clearnet traffic through Tor) with no per-client config.

Structured to match the sibling [`tailscale-mikrotik`](../tailscale-mikrotik)
project: same dual-arch build model, same management-SSH pattern, same
env-driven container. The RouterOS-side plumbing (bridges, veth, DNS forward,
`10.192.0.0/10` route, `TransPort` dst-nat) lives in
[`yt/bgp-setup/tor-setup`](../yt/bgp-setup/tor-setup).

> For research and testing. This runs a Tor **client** only (never a relay or
> exit — see `torrc`). Tor carries **TCP and DNS** only; UDP, ICMP and QUIC do
> not traverse Tor, which is why the router scopes what gets redirected.

## How `.onion` transparent routing works

`.onion` addresses are **not IP-routable** — you cannot add a route for them.
The transparent-proxy pattern uses DNS + TCP redirection instead:

1. Tor's **`DNSPort`** resolves `.onion` (and `.exit`) to a synthetic IP from
   `VirtualAddrNetworkIPv4` (default `10.192.0.0/10`).
2. Tor's **`TransPort`** accepts TCP to those synthetic IPs and carries the
   connection through the Tor network to the real hidden service.
3. On the router you forward the `.onion` DNS zone to `DNSPort`, route
   `10.192.0.0/10` at this container, and dst-nat TCP to `TransPort`.

DNS forward alone is necessary but **not sufficient** — without the route +
`TransPort` redirect, names resolve to `10.192.x.x` and then go nowhere.

## Requirements

RouterOS v7.6+ with the Container package, container `device-mode` enabled
(needs physical confirmation + reboot), and external storage (USB/NVMe)
recommended over internal NAND.

## Build

`build.sh` builds for **two MikroTik CPU families** and emits one
container-archive tar per arch:

| Output tar | buildx platform | Runtime base | Devices |
| ---------- | --------------- | ------------ | ------- |
| `tor-arm32.tar` | `linux/arm/v5` | `arm32v5/debian` (soft-float) | hAP ax S / hEX Refresh (**EN7562CT**) |
| `tor-arm64.tar` | `linux/arm64` | `arm64v8/debian` | **RB5009** (Cortex-A72) and aarch64 |

The EN7562CT container runtime tolerates only **arm32v5 soft-float** (ARMv7 /
hard-float `SIGILL`), so the arm32 image uses Debian's soft-float port — the
same runtime base proven by the tailscale arm32 image. arm64 has no such
restriction.

Tor is installed from the Debian archive per arch, so there is **no
cross-compile step** — the build runs entirely in the target-arch base image
(under QEMU when cross-building).

1. (Cross-arch only) register QEMU once:

   ```
   docker run --privileged --rm tonistiigi/binfmt --install all
   ```

2. Build:

   ```
   ./build.sh          # -> tor-arm32.tar AND tor-arm64.tar
   ./build.sh arm64    # arm64 only
   ./build.sh arm32    # arm32 only
   ```

### Which tar for which device

| Device | CPU | Upload |
| ------ | --- | ------ |
| router (RB5009) | arm64 | `tor-arm64.tar` |
| distsw | check `/system/resource/print` `architecture-name` | `arm64` → `-arm64`, `arm` → `-arm32` |
| hap1–hap5 (hAP ax S) | arm32v5 | `tor-arm32.tar` |

## Container environment variables

All optional; defaults suit the fabric. Set via `/container/envs`.

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `PASSWORD` | (unset) | root password for the management SSH server |
| `TRANS_PORT` | `9040` | Tor `TransPort` (transparent TCP) |
| `DNS_PORT` | `9053` | Tor `DNSPort` |
| `SOCKS_PORT` | `9050` | Tor `SOCKSPort` (set `0` to disable) |
| `VIRTUAL_ADDR_NET` | `10.192.0.0/10` | `VirtualAddrNetworkIPv4` — **must match the route + dst-nat on the router** |
| `LISTEN_ADDR` | `0.0.0.0` | address Tor binds ports on (so the router reaches them over the veth) |
| `EXIT_NODES` | (unset) | optional Tor `ExitNodes` value, e.g. `{us}` (adds `StrictNodes 1`) |
| `EXTRA_TORRC` | (unset) | path to an extra torrc fragment to append (e.g. a mounted file) |
| `TOR_ARGS` | (unset) | extra args appended to the `tor` command line |

`tor.sh` writes these into `/var/lib/tor/torrc.runtime`, which the baked
`/etc/tor/torrc` `%include`s. You can also bind-mount your own `torrc` fragment
and point `EXTRA_TORRC` at it.

## Management

The container runs an SSH server (root, `PASSWORD`) reachable on its veth
address, or use the router CLI:

```
/container/shell [find where hostname~"tor"]
# tor --version
# cat /var/lib/tor/torrc.runtime
```
