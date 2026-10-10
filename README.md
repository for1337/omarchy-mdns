# leo.mdns

I wanted to know what was on my home network. Nothing fancy — just a list of devices and a heads-up when something new showed up. This is a small Omarchy plugin that watches `avahi-browse`, listens to `ip monitor neigh` for the silent devices that don't advertise mDNS, remembers everything, and surfaces it as a bar widget + popup.

![screenshot placeholder](screenshots/popup.png)

## what it does

Streams `avahi-browse -a -r -f -p` and `ip -4 monitor neigh`, dedupes per IP, fills in the MAC via `ip neigh` (pinged once if the neighbour table hasn't caught up yet), and persists to `~/.local/state/omarchy/mdns-devices.json` so it survives shell restarts. A notification fires the first time a device appears — join has a 3s grace so mDNS has time to resolve the hostname before the popup, leave has a 30s debounce. The bar widget is a counter; the popup has hostname, IP, MAC, services, source, last-seen.

## requirements

- Omarchy shell. `omarchy`, `omarchy-shell`, `omarchy bar move` on `$PATH`.
- `avahi` — `sudo pacman -S avahi && sudo systemctl enable --now avahi-daemon` if it isn't already running.
- `ip` from `iproute2` (you almost certainly have it).
- A Nerd Font for the radar glyph `󰐷` (U+F0437). JetBrainsMono Nerd Font, which Omarchy ships by default, has it.

## install

```
git clone https://github.com/for1337/omarchy-mdns.git
cd omarchy-mdns
./install.sh --enable
```

`install.sh` symlinks `leo.mdns/` into `~/.config/omarchy/plugins/`, adds the plugin to `~/.config/omarchy/shell.json`, and asks Omarchy to place the bar widget in the right section. Re-run with `--force` if a previous install left a real folder at the target. `uninstall.sh` is the inverse (`--purge` also deletes the device cache).

```
omarchy restart shell
```

## using it

Hover the bar icon for the count, click for the popup, hit Clear if you want a fresh start. From the shell:

```
omarchy-shell leo.mdns toggle
omarchy-shell leo.mdns open
omarchy-shell leo.mdns close
```

You can hand-edit the cache file and `omarchy restart shell` — the watcher hydrates from disk on startup. `firstSeen` / `lastSeen` are epoch milliseconds.

## quirks

- IPv4 only. mDNS also publishes IPv6 (link-local, mostly), but those addresses change per interface and aren't what "what's on my network?" usually means.
- The watcher sees every interface except `lo`. Docker bridges, wireguard tunnels, anything — they all show up. Usually fine; sometimes noisy.
- MAC lookup is best-effort. iOS devices that go to sleep won't respond to ARP; their MAC column stays empty.
- Re-notify window is 10 minutes (`reNotifyMs`); rapid-fire mDNS re-announcements are filtered by a 30s gap (`minNotifyGapMs`). Both in `Service.qml`.
- After editing `Panel.qml` you need `omarchy bar move leo.mdns --section <current>` to re-mount the widget. Same as every other Omarchy bar widget — Quickshell hot-reload doesn't always re-instantiate `BarIconButton`.

## development

Debug logs:

```
tail -f /run/user/1000/quickshell/by-id/$(ls -t /run/user/1000/quickshell/by-id/ | head -1)/log.qslog | grep -i mdns
```

Exercise the watcher without waiting for the network:

```
avahi-publish -s "TestDevice" "_http._tcp" 80
```

(Ctrl-C to stop.) Validate the manifest:

```
omarchy plugin validate leo.mdns/
```

## license

MIT.
