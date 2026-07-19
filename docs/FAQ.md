# FAQ

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
