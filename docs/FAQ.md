# FAQ

## Start here: Diagnostics

**Settings > Games on Whales > Diagnostics** prints a read-only report — the
configured run UID/GID, the UID saved for already-paired clients, ownership of
the app state folders, whether Wolf's `fake-udev` helper can run, the installed
udev rules, and the ownership of Wolf's runtime socket volume. It changes
nothing and is safe to run while streaming.

Every check that fails is printed with what it breaks and how to fix it. Include
the output when reporting an issue; it answers most of the questions below
without a round trip. From a terminal it is
`bash /boot/config/plugins/gow/scripts/diagnose.sh`.

## NVIDIA Wayland support (nvidia_drm.modeset)

Wolf composes its game stream through a Wayland compositor, and Wayland on
NVIDIA hardware requires the `nvidia_drm` kernel module to load with
`modeset=1`. Without it, Wolf either fails to start the compositor or the
remote client shows a black frame.

### Check

```bash
cat /sys/module/nvidia_drm/parameters/modeset
```

This should print `Y`. If it prints `N`, or the file does not exist, modeset
is off.

### Fix

1. Open **Tools > System Drivers** in the Unraid webGui.
2. Find `nvidia_drm` in the driver list.
3. Click the edit/config action for that row.
4. In **Modprobe.d Config File**, enter exactly:

   ```text
   options nvidia_drm modeset=1
   ```

5. Apply the change and reboot so the module reloads with the new parameter.

Unraid persists that editor content under
`/boot/config/modprobe.d/nvidia_drm.conf` and copies it into `/etc/modprobe.d`
at boot. If you prefer editing `syslinux.cfg`, the equivalent kernel command
line option is `nvidia-drm.modeset=1`; do not put that kernel-command-line form
inside the Modprobe.d Config File editor.

### References

- Unraid forum thread: https://forums.unraid.net/topic/98978-plugin-nvidia-driver/page/164/#findComment-1425257
- Short summary: "for Wayland support, you need to set `nvidia_drm` modeset
  in Tools > System Drivers for your driver, then restart."

## NVIDIA stream disconnects with "no video received" (zero-copy)

Wolf uses a zero-copy NVIDIA pipeline that keeps frames in GPU (CUDA) memory for
the lowest latency. On some newer NVIDIA driver branches this pipeline fails to
negotiate, so Moonlight connects, shows the desktop for a few seconds, then
disconnects with **"no video received from host"**. The built-in "Pong" test app
(which does not exercise the same scaling path) may still work.

### Check

Look in the Wolf container log for a GStreamer negotiation failure right before
the stream ends, for example:

```text
cudaconvertscale ... transform could not transform video/x-raw(memory:CUDAMemory) ...
Internal data stream error.
streaming stopped, reason not-negotiated (-4)
[GSTREAMER] Pipeline error: Internal data stream error.
```

### Fix

Turn off the zero-copy pipeline so Wolf falls back to its legacy pipeline:

1. Open **Settings > Games on Whales** and click **Reconfigure**.
2. Uncheck **NVIDIA zero-copy pipeline**.
3. Click **Install** to re-deploy.

This sets `WOLF_USE_ZERO_COPY=FALSE` on the Wolf container. It trades a little
latency for a stream that negotiates correctly. Leave the option enabled if your
driver works with it — zero-copy is the faster path.

## Apps never start after updating (app state owned by the wrong user)

Wolf runs the apps it launches as a fixed UID/GID and bind-mounts
`<appdata>/profile-data/<profile>/<app>` in as the app's home directory. The
plugin defaults that to Unraid's `nobody:users` (99:100) and you can change it
under **App run UID / GID** in the setup form. Neither Wolf nor the app images
re-own state that is already on disk, so app data written under a different UID —
anything created before plugin 2026.07.19 — stays unwritable and the app dies
during startup. Steam is the usual casualty: the container comes up, the desktop
and taskbar appear, but Big Picture never opens.

### Check

In the app container's log, the startup gets as far as the runtime and then
stops, with no window ever appearing:

```text
Setting default user uid=99(retro) gid=100(retro)
steam.sh[226]: Running Steam on ubuntu 25.04 64-bit
setup.sh[317]: Steam runtime environment up-to-date!
```

Confirm the mismatch from the Unraid terminal — anything not owned by the
configured run UID (99 by default) under the app state folder is the problem:

```bash
find /mnt/user/appdata/gow/profile-data -maxdepth 4 ! -user 99 -printf '%u %p\n' | head
```

### Fix

Open **Settings > Games on Whales** and click either **Install** or **Update
Images**. Both re-own the app state to the configured UID/GID and update the
UID/GID saved for already-paired Moonlight clients.

The first run after changing the UID/GID walks the whole tree, so it can take a
while if the Steam library is large. The result is recorded in
`<appdata>/cfg/.run-ids` and skipped afterwards — but the tree is spot-checked
each time, so a stamp can never mask state that has drifted back.

The plugin also installs an inheritable ACL on the two app-state roots. Wolf
runs as root and creates a client's app home only when that app is first
launched, which can be later than deployment; the ACL lets the configured app
UID/GID write those newly created directories immediately. The next Install or
Update Images normalizes their ownership without walking an already-clean Steam
library.

This prevention requires an ACL-capable appdata filesystem and the `setfacl`
utility. If either is unavailable, Install / Update Images prints a warning;
existing state is still repaired, but a first app home created later by Wolf may
need another ownership repair.

Some directories under an app home are intentionally owned by root services,
not by the app user. In particular, Wolf manages `udev/`, while the Steam
container's root init and Decky Loader manage `homebrew/services/` and
`homebrew/plugins/`. Decky resets its plugin directory to root-owned mode `0755`
on every start, which also clips inherited ACL write access. Diagnostics excludes
these service-only paths while continuing to verify and repair user state such
as `.steam/` and the app home itself.

If your app data was written by Wolf's own default user and you would rather
keep it that way, set **App run UID / GID** to `1000:1000` in the setup form
instead; the same migration then re-owns everything to that pair.

## Controllers never appear inside an app (fake-udev)

Wolf hot-plugs your controller into the running app container by copying a
helper called `fake-udev` into the appdata folder, bind-mounting it into the
container as `/usr/bin/fake-udev`, and executing it there. If that helper cannot
be executed, the app sees no input devices — sway logs
`Path '/dev/input/*' is not present.` and the controller does nothing.

### Check

Wolf's own log shows the exec failing with status 126:

```text
WARN | Docker exec failed (126), /bin/bash: line 1: /usr/bin/fake-udev: Permission denied
```

**Diagnostics** reports the same thing under *Controller hot-plug (fake-udev)*.

### Fix

Two causes, both reported by Diagnostics:

- **The helper lost its executable bit.** Wolf refreshes it with `cp`, which
  keeps the mode of an existing file, so a copy that once landed without `+x`
  stays broken. Re-deploy (**Install** or **Update Images**) — the plugin now
  restores the bit before starting Wolf.
- **Appdata is on a `noexec` mount.** Nothing can execute from there, so no
  chmod helps. This shows up on some Unassigned Devices shares. Move appdata to
  a share mounted without `noexec`, or remount it.

## Moonlight discovery and mDNS/Avahi warnings

Wolf advertises the Moonlight service with mDNS on UDP port 5353. Unraid also
commonly runs `avahi-daemon` on the same port. When both are active, Avahi may
log a warning like:

```text
Detected another IPv4 mDNS stack running on this host.
```

This does not normally stop the GoW plugin or Wolf containers from starting,
but it can make Moonlight automatic discovery unreliable.

### Check

```bash
ss -ulpn | grep 5353
```

If the output shows both `avahi-daemon` and `wolf`, discovery may be flaky.

### Workaround

Use the direct pairing URL shown on the GoW settings page, or manually add the
Unraid server IP in Moonlight. Do not disable Unraid's Avahi service unless you
understand the impact on other Unraid network discovery features.
