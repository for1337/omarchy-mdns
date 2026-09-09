# leo.mdns

I wanted to know what was on my home network. Nothing fancy — just a list of devices, with a heads-up when something new showed up. Existing tools either log to syslog or want a full monitoring setup. This is a small Omarchy plugin that watches `avahi-browse`, remembers every device it sees, and surfaces them as a bar widget + popup.

![screenshot placeholder](screenshots/popup.png)

## What it actually does

Streams `avahi-browse -a -r -f -p`, dedupes by `(hostname, IPv4)`, looks up the MAC via `ip neigh` (one ping round-trip if the neighbour table hasn't caught up yet), and keeps everything in `~/.local/state/omarchy/mdns-devices.json` so it survives shell restarts. A desktop notification fires the first time a device appears and again after 10 minutes of silence. The bar widget shows the live count in its tooltip; the popup has hostname, IP, MAC, services, last-seen.

## requirements

- Omarchy shell. `omarchy`, `omarchy-shell`, `omarchy bar move` on `$PATH`.
- `avahi` — `sudo pacman -S avahi && sudo systemctl enable --now avahi-daemon` if it isn't already running.
- Python 3. Used only for an atomic JSON write; if you have a working Omarchy install, you have this.
- A Nerd Font for the radar glyph `󰐷` (U+F0437). JetBrainsMono Nerd Font, which Omarchy ships by default, has it.

## install

Once the repo is on GitHub:

```
omarchy plugin add https://github.com/for1337/omarchy-mdns --enable
omarchy bar move leo.mdns --section right
omarchy restart shell
```

If you're hacking on it locally:

```
git clone https://github.com/for1337/omarchy-mdns.git
cd omarchy-mdns
./install.sh --enable
```

`install.sh` symlinks `leo.mdns/` into `~/.config/omarchy/plugins/`, drops an entry into `~/.config/omarchy/shell.json`, and asks Omarchy to put the bar widget in the right section. Re-run with `--force` if a previous install left a real folder in the way. Pass `--help` for the full flag list; `uninstall.sh` is the inverse (and `--purge` deletes the device cache too).

## using it

Hover the bar icon for the count, click for the popup, hit Clear if you want a fresh start. From the shell:

```
omarchy-shell leo.mdns toggle
omarchy-shell leo.mdns open
omarchy-shell leo.mdns close
```

You can hand-edit the cache file and `omarchy restart shell` — the watcher hydrates from disk on startup. `firstSeen` / `lastSeen` are epoch milliseconds.

## quirks I should mention

- IPv4 only. mDNS also publishes IPv6 (link-local, mostly), but those addresses change per interface and aren't what "what's on my network?" usually means.
- The watcher sees every interface except `lo`. Docker bridges, wireguard tunnels, anything — they all show up. Usually fine; sometimes noisy.
- MAC lookup is best-effort. iOS devices that go to sleep won't respond to ARP; their MAC column stays empty.
- Re-notify window is 10 minutes of silence, with a 30s backstop for shell restarts. Tunable in `Service.qml` (`reNotifyMs`, `minNotifyGapMs`).
- After editing `Panel.qml` you need `omarchy bar move leo.mdns --section <current>` to re-mount the widget. Same as every other Omarchy bar widget — Quickshell hot-reload doesn't always re-instantiate `BarIconButton`.

## development

Debug logs:

```
tail -f /run/user/1000/quickshell/by-id/$(ls -t /run/user/1000/quickshell/by-id/ | head -1)/log.qslog | grep -i mdns
```

To exercise the watcher without waiting for the network to do something:

```
avahi-publish -s "TestDevice" "_http._tcp" 80
```

(Ctrl-C to stop.) Validate the manifest:

```
omarchy plugin validate leo.mdns/
```

## license

MIT.