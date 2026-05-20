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
