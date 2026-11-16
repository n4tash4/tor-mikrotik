# tor-mikrotik

A [Tor](https://www.torproject.org/) client in a [RouterOS container](https://help.mikrotik.com/docs/display/ROS/Container), set up as a transparent proxy. LAN clients open `.onion` addresses with no proxy settings.

The container runs a Tor client only. `torrc` sets `ExitRelay 0` and `ClientOnly 1`, so the container never relays traffic for others. Tor carries TCP and DNS. UDP, ICMP, and QUIC do not go through Tor.

The examples use a container at `172.30.0.3` behind a bridge with the gateway `172.30.0.1`. Replace these with your own values.

## How transparent `.onion` routing works

A `.onion` name has no real address, so the setup combines DNS with a TCP redirect:

1. Tor's `DNSPort` answers a `.onion` lookup with an address from `VIRTUAL_ADDR_NET`, `10.192.0.0/10` by default.
2. The router routes `VIRTUAL_ADDR_NET` to the container and keeps the destination address.
3. Inside the container, an `iptables` `REDIRECT` sends that TCP traffic to Tor's `TransPort`.
4. Tor reads the original destination and opens the connection to the onion service.

The `REDIRECT` must happen inside the container, in Tor's own network namespace. Do not replace it with a RouterOS `dst-nat` rule for `VIRTUAL_ADDR_NET`. Tor finds the original destination with `SO_ORIGINAL_DST`, which works only when the NAT happened in the namespace where Tor runs. If the router does the NAT, Tor logs `Fetching original destination failed` and drops every flow.

Nothing in the code checks this. You get it by running the container with `privileged=yes` and `TRANSPARENT_REDIRECT=Y`, which makes `tor.sh` install the rule.

The `dst-nat` rules in [Configure the router](#configure-the-router) are for DNS only. DNS does not need the original destination.

## Requirements

- RouterOS 7.6 or later with the `container` package and container mode enabled.
- An ext4 disk mounted at `/storage`.
- To build, Docker with Buildx, and `skopeo`. To build arm32 on another architecture, register QEMU once:

	```sh
	docker run --privileged --rm tonistiigi/binfmt --install all
	```

## Build

```sh
./build.sh          # writes tor-arm32.tar and tor-arm64.tar
./build.sh arm64    # arm64 only
./build.sh arm32    # arm32 only
```

The script builds without the Docker cache, loads each image as `tor-mikrotik:0.1.0-<arch>`, and exports it with `skopeo`.

| File | Platform | Base image | Devices |
|---|---|---|---|
| `tor-arm64.tar` | `linux/arm64` | `arm64v8/debian:bookworm-slim` | arm64 boards, such as the RB5009. |
| `tor-arm32.tar` | `linux/arm/v5` | `arm32v5/debian:bookworm-slim` | EN7562CT boards, such as the hAP ax S and hEX Refresh. |

The EN7562CT container runtime raises `SIGILL` on ARMv7 hard-float code, so the arm32 image uses Debian's soft-float `armel` port.

To find a device's architecture, run `/system/resource/print` and read `architecture-name`.

## Paths on the device

| Path | Purpose |
|---|---|
| `/storage/tor-<arch>.tar` | Image file. |
| `/storage/containers/tor` | Container root-dir. RouterOS deletes it when you remove the container. |
| `/storage/container-data/tor/data` | Mounted at `/var/lib/tor`. Tor's keys, consensus cache, and `torrc.runtime`. |
| `/storage/container-data/tor/ssh-host-keys` | Mounted at `/etc/ssh/host-keys`. SSH host keys. |

Do not nest the host-key mount under the data mount. `tor.sh` runs `chown -R debian-tor` on `/var/lib/tor`, which would change the owner of the SSH host keys and make sshd refuse them.

## Environment variables

All variables are optional.

| Variable | Default | Description |
|---|---|---|
| `AUTHORIZED_KEYS` | | OpenSSH public keys for `root`, one per line. If unset, nobody can log in over SSH. |
| `TRANSPARENT_REDIRECT` | `N` | `Y` adds the in-container `REDIRECT` for `VIRTUAL_ADDR_NET`. Needs `privileged=yes`. |
| `VIRTUAL_ADDR_NET` | `10.192.0.0/10` | Value for `VirtualAddrNetworkIPv4`. Must match the route on the router. |
| `TRANS_PORT` | `9040` | `TransPort`. |
| `DNS_PORT` | `9053` | `DNSPort`. |
| `SOCKS_PORT` | `9050` | `SocksPort`. `0` turns it off. |
| `LISTEN_ADDR` | `0.0.0.0` | Address the Tor ports bind to. |
| `EXIT_NODES` | | Value for `ExitNodes`, for example `{us}`. Also sets `StrictNodes 1`. |
| `EXTRA_TORRC` | | Path to a torrc fragment inside the container, for example a mounted file. `tor.sh` appends it only if the file exists. |
| `TOR_ARGS` | | Extra arguments for the `tor` command. |

At start, `tor.sh` writes these settings to `/var/lib/tor/torrc.runtime` and prints the file to the container log. The `/etc/tor/torrc` baked into the image includes that file. It also sets `SocksPolicy accept *`, so any client that can reach the SOCKS port can use it.

## Ports

| Port | Use |
|---|---|
| 9040/tcp | `TransPort`. |
| 9053/udp, 9053/tcp | `DNSPort`. |
| 9050/tcp | `SocksPort`. |
| 22/tcp | SSH, public key only. |

## Deploy

Run these commands on the device that hosts the container:

```
/interface/veth/add name=veth-tor address=172.30.0.3/16 gateway=172.30.0.1
/interface/bridge/port/add bridge=containers interface=veth-tor
/container/envs/add list=tor key=AUTHORIZED_KEYS value="<your-ssh-public-key>"
/container/envs/add list=tor key=TRANSPARENT_REDIRECT value=Y
/container/mounts/add list=tor src=/storage/container-data/tor/data dst=/var/lib/tor
/container/mounts/add list=tor src=/storage/container-data/tor/ssh-host-keys dst=/etc/ssh/host-keys
/container/add file=storage/tor-arm64.tar interface=veth-tor envlists=tor mountlists=tor \
	root-dir=/storage/containers/tor hostname=tor privileged=yes \
	start-on-boot=yes logging=yes
```

Upload `tor-arm64.tar` (or `tor-arm32.tar`) to `/storage` first. Wait until the container's status is `stopped`, then start it:

```
/container/start [find where hostname="tor"]
```

## Configure the router

On the router that serves DNS to your LAN, forward the `.onion` zone to the container:

```
/ip/dns/static/add type=FWD name=onion match-subdomain=yes forward-to=172.30.0.3
```

On the device that hosts the container, redirect DNS to Tor's `DNSPort` and route the virtual address range to the container:

```
/ip/firewall/nat/add chain=dstnat dst-address=172.30.0.3 protocol=udp dst-port=53 action=dst-nat to-ports=9053
/ip/firewall/nat/add chain=dstnat dst-address=172.30.0.3 protocol=tcp dst-port=53 action=dst-nat to-ports=9053
/ip/route/add dst-address=10.192.0.0/10 gateway=172.30.0.3
```

If the LAN is behind another router, route `10.192.0.0/10` to the container host from there too.

Without the route, `.onion` names resolve to `10.192.x.x` addresses and connections to them go nowhere. Without the in-container `REDIRECT`, Tor never sees the connections.

## Verify

1. Read the container log. Tor logs `Bootstrapped 100%` when it has connected, and `tor.sh` logs `PREROUTING REDIRECT rule installed OK` when the redirect is in place:

	```
	/log/print where message~"Bootstrapped"
	```

2. Open a shell in the container and list the redirect rule and the generated config:

	```
	/container/shell [find where hostname="tor"]
	# iptables -t nat -S PREROUTING
	# cat /var/lib/tor/torrc.runtime
	```

3. From a LAN client, resolve an onion address. The answer must be in `10.192.0.0/10`:

	```sh
	nslookup <onion-address>.onion
	```

4. Fetch the page from the same client, with no proxy settings:

	```sh
	curl http://<onion-address>.onion/
	```

If the log shows `Fetching original destination failed`, a RouterOS `dst-nat` rule is redirecting TCP traffic for `VIRTUAL_ADDR_NET` before it reaches the container. Remove that rule.

If the log shows `NAT TABLE NOT ACCESSIBLE`, the container is not privileged. Set `privileged=yes` and add the container again.

## Upgrade

If other containers on the device use the same Debian base, stop all of them before you add the new image. When a container that shares a layer is running, extraction fails with `Text file busy`.

1. Upload the new tar.
2. Stop every container: `/container stop [find]`.
3. Remove the tor container.
4. Add it again with the same settings. Wait until its status is `stopped`.
5. Start all containers.

The `/storage/container-data/tor` directories survive, so Tor keeps its keys and the SSH host keys stay the same.

## Remove

1. Stop and remove the container:

	```
	/container/stop [find where hostname="tor"]
	/container/remove [find where hostname="tor"]
	```

2. Remove the interface, the env and mount lists, and the router configuration:

	```
	/interface/bridge/port/remove [find where interface=veth-tor]
	/interface/veth/remove [find where name=veth-tor]
	/container/envs/remove [find where list=tor]
	/container/mounts/remove [find where list=tor]
	/ip/dns/static/remove [find where name=onion]
	/ip/firewall/nat/remove [find where dst-address=172.30.0.3]
	/ip/route/remove [find where dst-address=10.192.0.0/10]
	```

3. Delete `/storage/container-data/tor` and `/storage/tor-<arch>.tar` if you no longer need Tor's keys or the image.

## SSH

`sshd` accepts public keys only. At start, `tor.sh` writes `AUTHORIZED_KEYS` to `/root/.ssh/authorized_keys`. If the variable is unset, it deletes that file and logs a warning, and only `/container/shell` works.

`tor.sh` creates the ed25519 and RSA host keys in `/etc/ssh/host-keys` if they are missing, so the host keys persist across upgrades. The image build deletes the Debian default host keys.

In a privileged container, RouterOS leaves the image files with a shifted owner, so `/root` isn't owned by root. sshd's `StrictModes` then rejects a correct `authorized_keys`. `tor.sh` sets the owner of `/root` and `/root/.ssh` to root at start.
