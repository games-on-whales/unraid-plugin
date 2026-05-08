# Community Applications submission checklist

This folder holds the templates Unraid Community Applications scans when it
indexes our repository:

- [`ca_profile.xml`](./ca_profile.xml) — maintainer profile (icon + blurb)
- [`gow.xml`](./gow.xml) — plugin template that points CA at `gow.plg`

The submission portal is **https://ca.unraid.net/submit** ([builders guide](https://ca.unraid.net/submit/help/builders)).
Submissions are reviewed by the CA moderation team within ~48h
([Unraid Docs](https://docs.unraid.net/unraid-os/using-unraid-to/run-docker-containers/community-applications/)).

## Manual steps left to do (only the maintainer can do these)

### 1. Get an Unraid forum support thread in Plugin Support

CA requires a dedicated support thread on `forums.unraid.net`. The
[Plugin Support subforum](https://forums.unraid.net/forum/61-plugin-support/)
**does not accept new threads from regular users** — only approved plugin
authors and moderators can create top-level topics there. There are three
paths, in priority order:

**Option A (try first): submit to CA and let the moderator place the thread.**
The submission portal at `ca.unraid.net/submit` is the current canonical
flow; if the CA moderator (Squid / the CA team) approves the repo, they
will typically create or place the Plugin Support thread on your behalf.
If you go this route, just submit the repo with the placeholder
`<Support>` URL pointing at the subforum index, and answer "support thread
pending CA review" if a reviewer asks.

**Option B: post in [General](https://forums.unraid.net/forum/77-general/) and
ask a mod to move it.** General accepts new threads from any registered
user. Title: `[PLUGIN] Games on Whales`. Body: short blurb, install URL
(`https://raw.githubusercontent.com/games-on-whales/unraid-plugin/main/gow.plg`),
link to the GitHub repo, link to [`docs/FAQ.md`](../docs/FAQ.md), and a
call-out that NVIDIA users need `nvidia_drm.modeset=1`. Once posted, hit
**Report** on your own first post and ask a moderator to move it to Plugin
Support.

**Option C: DM `@Squid`** (forum profile 10290) asking for a Plugin Support
thread to be opened for an upcoming CA submission. Slowest but works if A
and B stall.

Whichever path, the end state is a URL like
`https://forums.unraid.net/topic/NNNNNN-plugin-games-on-whales/`.

### 2. Wire the forum URL into the plugin

Once you have the thread URL, replace the placeholder in three places:

- [`gow.plg`](../gow.plg) — `support="..."` attribute (currently the Discord URL)
- [`unraid-ca/gow.xml`](./gow.xml) — `<Support>` element (currently points at
  the subforum index, not a specific thread)
- [`README.md`](../README.md) — the `Forum thread (Unraid):` TODO line

Tag a new release (e.g. `2026.04.27`) so the bumped `support=` ships in
the next install.

### 3. Submit at https://ca.unraid.net/submit

1. Sign in with an Unraid account that owns or is authorised for the
   `games-on-whales/unraid-plugin` GitHub repository.
2. **Add Repository** — paste `https://github.com/games-on-whales/unraid-plugin`.
3. **Review** — the scanner will pick up `unraid-ca/ca_profile.xml` and
   `unraid-ca/gow.xml`. Fix anything it flags.
4. **Submit** — confirm and wait for moderator review (~48h).

### 4. After approval

The plugin will appear in CA search as **Games on Whales**. Future releases
just need a new git tag — CA picks up the version from `gow.plg` on each
indexer run, no resubmission needed unless template metadata changes.
