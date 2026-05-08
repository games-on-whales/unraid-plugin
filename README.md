# Games on Whales — Unraid plugin

Run [Games on Whales](https://games-on-whales.github.io) on your Unraid
server: stream games and desktops to any [Moonlight](https://moonlight-stream.org)
client (Steam Deck, Apple TV, mobile, desktop) over your LAN or the internet.

The plugin deploys [Wolf](https://github.com/games-on-whales/wolf) (the
streaming server) and [Wolf Den](https://github.com/games-on-whales/wolf-den)
(the on-host launcher UI) via Docker Compose, and adds a Settings page under
**Settings → Games on Whales** for picking a GPU, choosing your appdata path,
and starting/stopping the stack.

## Status

Beta. Several people are running it daily, but rough edges still exist. The
plugin doesn't make permanent changes to your system — uninstalling is a
clean rollback if anything goes wrong.

## Requirements

- Unraid 6.12 or newer
- The **Compose Manager** plugin (install from Community Applications first —
  the GoW installer refuses to proceed without it)
- A GPU that Wolf supports (Intel, AMD, or NVIDIA)
- NVIDIA users: `nvidia_drm` must load with `modeset=1`. See
  [docs/FAQ.md](docs/FAQ.md) before installing — without modeset, Wolf will
  black-screen or crash on stream start.

## Installation

1. In the Unraid webGui, go to **Plugins → Install Plugin**.
2. Paste the plugin URL and click **Install**:

   ```
   https://raw.githubusercontent.com/games-on-whales/unraid-plugin/main/gow.plg
   ```

3. After install completes, open **Settings → Games on Whales** to configure
   your GPU and appdata path, then click **Deploy**.

You should see output like:

```
╔════════════════════════════╗
║ Installing Games on Whales ║
╚════════════════════════════╝
....
╔══════════╗
║ Complete ║
╚══════════╝
```

## Configuration

The Settings page (**Settings → Games on Whales**) covers:

- **GPU selection** — multi-GPU systems get a picker; the chosen GPU is
  passed through to the Wolf container.
- **Appdata path** — where Wolf and Wolf Den persist their state. Defaults
  to `/mnt/user/appdata/gow`.
- **Deploy / Start / Stop / Update** — buttons that wrap the underlying
  `docker compose` calls so you don't have to drop to the shell.

Persistent udev rules and an auto-start hook are written to
`/boot/config/go` so the stack comes back up after a reboot.

## Pairing a Moonlight client

Once the stack is running, point your Moonlight client at the Unraid
server's IP. Wolf will surface a one-time PIN URL on the host; open it in a
browser, paste the PIN your Moonlight client shows, and you're paired.

## Troubleshooting

See [docs/FAQ.md](docs/FAQ.md). NVIDIA users in particular should read the
`nvidia_drm.modeset` section before reporting black-screen or crashed-Wolf
issues.

## Support

- **Forum thread (Unraid):** TODO — replace with link once the support
  thread is opened.
- **Discord:** https://discord.gg/kRGUDHNHt2
- **Issues:** https://github.com/games-on-whales/unraid-plugin/issues

## License

[MIT](LICENSE).

## Developer notes

See [DEVELOPING.md](DEVELOPING.md).
