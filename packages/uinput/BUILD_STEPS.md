## How to Build

Eventually, this needs to be automated. But for now, here's how to build this package.

1. Make a temporary directory (`[tmp dir]`) to create the package structure in.
2. Copy the contents of `root` to `[tmp dir]`.
3. Delete `[tmp dir]/lib/modules/*-Unraid` for the kernel versions you are not building. (It's preferred to build separate packages for each version to help prevent version mismatches).
4. `cd` to `[tmp dir]`.
5. Run `/utils/fmakepkg.sh ../uinput.txz`
6. Move `../uinput.txz` to `/kernel-bin/[kernel ver]/uinput.txz`
7. Generate `/kernel-bin/[kernel ver]/uinput.txz.md5`

Some notes for the future:
* Maybe deleting the "bad" modules should be done as a post-install step after actually downloading/installing the package? That would make the install script a little more complicated, and it would make the download bigger (assuming many versions) but there'd only be a single package... food for thought.
