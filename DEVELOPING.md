# Developer How-To

## Prerequisites

unRAID installs plugins from an HTTP server, so in order to install your locally-modified version you'll need some way to serve the files over HTTP.  There is no HTTP server included with this distribution, but several popular development environments include an easy way to launch one.

1. NodeJS. This is the one I use.  Just run `npx http-server` in the top level of the plugin repo (the directory that contains this file).  This will serve the files at `http://[your ip address]:8080/`.
2. Python (3+).  This is untested, but it should work.  Run `python -m http.server 8080` and the files will (should) be available at `http://[your ip address]:8080/`.

## Getting Started

Open up [`gow.plg`](gow.plg) and change the `gitPkgURL` entity to point to `http://[your ip address]:8080`. Be sure to use the IP address of the system you're doing the dev work on; this may not necessarily be your unRAID server. It should _not_ end with a trailing slash.  Also change the `gitReleaseURL` entity to `http://[your ip address]:8080/package-dist`. It should likewise have no trailing slash.

The majority of the functionality of this plugin is implemented in various "packages" (see the `packages/` directory); this provides a convenient mechanism to break the work down into manageable chunks with a standardized way of installing, uninstalling, reloading after reboot, etc.

Installing and uninstalling packages is managed by the [`preinstall.sh`](scripts/preinstall.sh), [`install.sh`](scripts/install.sh), and [`uninstall.sh`](scripts/uninstall.sh) scripts.  Any time you modify one of these, you'll need to update the MD5 and SHA256 hashes in [`gow.plg`](gow.plg).  The SHA256 hash takes precedence if both exist, but the MD5 hash is left in for older versions of unRAID. (TODO: it's possible we don't need these anymore)

Now it's time to try installing your development version of the plugin.  Open a terminal on your unRAID server and uninstall the old version of GoW (if you have one installed), then install the new version:
```sh
$ plugin remove gow.plg
$ plugin install http://[your ip address]:8080/gow.plg
```

## How to add a new package

1. Create a new directory under `packages/`, let's say `packages/new-pkg`.
2. In `packages/new-pkg`, add a file called `root/install/slack-desc`.  It's easiest to copy an existing one and modify it.
3. Build any directory structure you like under `root/`.  Any files you add will be automatically installed in their corresponding places under `/` when the plugin is installed or reloaded after reboot.
4. If your new package needs to perform any actions on start or stop, add a shell script in `root/boot/config/plugins/gow/scripts/start/new-pkg.sh` or `root/boot/config/plugins/gow/scripts/stop/new-pkg.sh`. `start` corresponds to when the plugin is installed or reloaded after reboot, while `stop` is when the plugin is uninstalled.

## How to build a package

Packages are built using the [`utils/fmakepkg.sh`](utils/fmakepkg.sh) script.  For the purposes of these steps, we'll assume the name of the package you're building is `your-pkg`.

1. Make a directory at the top level called `package-dist` to hold packages while you're working on them.
2. `cd` to `packages/your-pkg/root`.
3. Run `../../../utils/fmakepkg.sh ../../../package-dist/your-pkg.txz`.
4. `cd` to `../../../package-dist`.
5. Generate `your-pkg.txz.md5` and `your-pkg.txz.sha256`.
6. Uninstall and reinstall the plugin as above to pick up the new package.


