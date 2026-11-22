# xray_channel

One-command installers for a private encrypted channel between a small client box (e.g. a Raspberry Pi at home) and
your own server, using [Xray-core](https://github.com/XTLS/Xray-core) with **VLESS + REALITY + Vision**.

- **REALITY**: the server borrows the TLS handshake of a real, large website (the "camouflage site"). On the wire the
  connection looks like an ordinary HTTPS visit to that site; a probe without your key is passed to the real site and
  sees its genuine certificate.
- **Vision** (`xtls-rprx-vision`): removes the "TLS inside TLS" traffic pattern.
- Keys, user IDs and short IDs are generated on your server. Nothing secret is stored in this repo.

```
client box (Pi) ──TLS 1.3 to :443, SNI = camouflage site──▶ your server (VM) ──▶ your network / internet
```

---

## 1. Server (VM in your data centre, Hong Kong, Singapore...)

Needs: a Linux VM (AlmaLinux/Rocky/RHEL 9-10, Debian 12, Ubuntu 22.04+) with a **public IPv4** and **TCP 443 free**.
Use a dedicated VM: don't install it on a host that already serves websites on 443.

```bash
sudo -i
curl -fsSL https://raw.githubusercontent.com/supernetuk/xray_channel/main/server/xray-channel-server \
  -o /usr/local/bin/xray-channel-server && chmod +x /usr/local/bin/xray-channel-server && xray-channel-server install
```

The installer downloads Xray (checksum verified), picks a camouflage site that offers TLS 1.3 + HTTP/2, generates the
REALITY keys, opens the firewall (firewalld/ufw), turns on BBR, creates the first user and **prints the one-line
client command** plus a `vless://` link (and a QR code) for phone/PC apps.

Options: `--port 443` `--sni www.example.com` `--host <public-ip-or-name>` `--user <first-user-name>`

### Manage users

| Command | What it does |
|---|---|
| `xray-channel-server add alice` | New user; prints alice's client command and link |
| `xray-channel-server client-cmd alice` | Print it again |
| `xray-channel-server list` / `del alice` | List / remove (link stops working at once) |
| `xray-channel-server bundle alice` | Offline package (`/root/xray-channel-alice.tar.gz`) for a client that can't reach GitHub |
| `xray-channel-server sni <domain>` | Change camouflage site (all clients need new links) |
| `xray-channel-server rotate-keys` | New REALITY keys (all clients need new links) |
| `xray-channel-server status` / `update` / `uninstall` | |

The server blocks traffic from clients to private/LAN addresses (so users can't reach your internal network) and
BitTorrent.

---

## 2. Client (Raspberry Pi or any small Linux box)

Run the command the server printed, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/supernetuk/xray_channel/main/client/xray-channel-client \
  -o /usr/local/bin/xray-channel-client && chmod +x /usr/local/bin/xray-channel-client \
  && xray-channel-client install --link 'vless://...' --mode proxy
```

### Modes

| Mode | Ports needed | How devices use it |
|---|---|---|
| `proxy` (default) | 1 | Set a proxy on each device: SOCKS5 `<pi-ip>:10808` or HTTP `<pi-ip>:10809` |
| `gateway` | 1 | "Side router": set each device's (or the home router's DHCP) **gateway and DNS** to the Pi |
| `router` | 2 | Pi sits between the ISP router (`--wan eth0`) and your devices (`--lan eth1`). Runs DHCP + DNS on the LAN (`192.168.88.0/24`, change with `--lan-ip`) |

`gateway` and `router` send all TCP/UDP from the LAN through Xray (transparent proxy with nftables TPROXY). DNS is
answered through Xray too. By default mainland China sites and IPs (`geosite:cn`, `geoip:cn`) go **direct** for speed
and everything else goes through the tunnel; use `--all-through-tunnel` to send everything through it.

Other commands: `xray-channel-client status`, `test`, `set-link 'vless://...'`, `update`, `uninstall`.

### Hardware

No standard Raspberry Pi has two Ethernet ports (Pi 4 / Pi 5: one Gigabit port + Wi-Fi). For `router` mode use either:

- **Raspberry Pi 5 or 4 + a USB 3 Gigabit Ethernet adapter** (RTL8153-based adapters work out of the box), or
- a dual-port router board running Debian/Ubuntu, e.g. **NanoPi R5S / R6S** or **Orange Pi R5 Plus**.

With one port, use `proxy` or `gateway` mode. Use a 64-bit OS (Raspberry Pi OS Bookworm 64-bit recommended).

### If GitHub is slow or blocked where the client is

1. Best: set the Pi up **before** you take it there (install with the link, test, then ship it), or
2. On the server: `xray-channel-server bundle <name>`, copy the `.tar.gz` to the Pi (USB stick / scp), then:
   ```bash
   tar xzf xray-channel-<name>.tar.gz && sudo bash xray-channel-<name>/install.sh --mode proxy
   ```

---

## Notes

- Nothing hides traffic perfectly forever: networks that filter traffic change their methods. Keep Xray updated
  (`update` on both sides) and be ready to change the camouflage site (`sni`) or port.
- Laws on encrypted tunnels and proxies differ by country. You are responsible for using this lawfully where you and
  your users are.

## Licence

MIT. Xray-core is MPL-2.0 and is downloaded from its official GitHub releases at install time.
