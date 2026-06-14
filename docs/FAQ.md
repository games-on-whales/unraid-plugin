# FAQ

## NVIDIA Wayland support (nvidia_drm.modeset)

Wolf composes its game stream through a Wayland compositor, and Wayland on
NVIDIA hardware requires the `nvidia_drm` kernel module to load with
`modeset=1`. Without it, Wolf either fails to start the compositor or the
remote client shows a black frame.

### Symptoms

Moonlight connects but shows **"No video received from host"** (or a black
screen), and the Wolf container log shows the EGL renderer failing to find the
NVIDIA GPU, falling back to Mesa/ZINK, then panicking:

```text
ERROR smithay::backend::egl::ffi: [EGL] 0x3003 (BAD_ALLOC) eglQueryDevicesEXT: EGL_BAD_ALLOC error: In eglQueryDevicesEXT: Failed to allocate device list.
libEGL warning: egl: failed to create dri2 screen
MESA: error: ZINK: failed to choose pdev
panicked at wayland-display-core/...: Failed to create EGLDisplay: InitFailed(Unknown(0))
```

The most common cause is `nvidia_drm modeset` being off — apply the fix below
and reboot.

> **Multiple NVIDIA GPUs?** This same EGL failure also appears when the selected
> render node (`WOLF_RENDER_NODE`, set from the GPU you pick on the settings
> page) points at a card that is not the one driving the display. If modeset is
> already `Y`, reconfigure in Settings > Games on Whales and select the other
> NVIDIA render node (`/dev/dri/renderD129`, etc.).

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
