# ClaudeMultiAcc

English | [Русский](README.ru.md)

A macOS menu bar app that lets you use several Claude Desktop accounts side by side. For each extra account it makes
a separate copy of Claude Desktop (a “clone”) with its own name, its own label on the icon and its own sign-in, and
keeps these copies up to date when Claude updates.

> **Unofficial.** ClaudeMultiAcc is an independent open-source project. It is not affiliated with, endorsed by or
> supported by Anthropic. “Claude” and “Claude Desktop” are trademarks of Anthropic, PBC, named here only to say which
> app this tool works with. Use it with your own accounts and within Anthropic’s terms.

## How it works

- The official `/Applications/Claude.app` is never modified. ClaudeMultiAcc copies it into a new app, for example
  `/Applications/Claude Work.app`, with its own bundle id (`com.imaxzone.claude.<name>`) and its own profile folder
  (`~/Library/Application Support/ClaudeProfiles/<name>`). The label is drawn inside the clone’s icon, so the Dock
  and Finder show it without a grey frame.
- Each clone is signed on your Mac with a permanent local certificate. ClaudeMultiAcc creates it by itself the first
  time you add an app and keeps it in a separate keychain file of its own: no Terminal, no keychain password. Because
  the certificate never changes, macOS keeps each clone’s permissions and keychain access between updates. The
  frameworks and helpers inside the app stay exactly as Anthropic ships them.
- When a new Claude comes out, ClaudeMultiAcc downloads it from Anthropic by itself, so you never have to open the
  official Claude for that, and rebuilds the clones: a closed clone right away, an open one as soon as you quit it, or
  when you click **Update**. It also notices when the official Claude updates itself.

## Install

### Requirements

- A Mac with Apple Silicon (M1 or newer) and macOS 26 or newer.
- Claude Desktop installed in **Applications** and signed in.
- An administrator account: clones are installed into **Applications**.

### Steps

1. Download `ClaudeMultiAcc-<version>.dmg` from
   [Releases](https://github.com/imaxzone/ClaudeMultiAcc/releases/latest).
2. Open it and drag **ClaudeMultiAcc** onto **Applications**.
3. Open ClaudeMultiAcc from Applications. macOS says it cannot verify the app: click **Done**.
4. Open **System Settings → Privacy & Security**, scroll down to “ClaudeMultiAcc was blocked…” and click
   **Open Anyway**, then confirm with your password or Touch ID (and **Open Anyway** once more if asked).
   Why: the app is not notarized by Apple (that needs a paid Apple Developer account), so macOS asks you to allow
   it by hand. You do this once for every version you download.
5. The ClaudeMultiAcc icon (two overlapping squares) appears in the menu bar. Click it, then **+ Add**.
6. Type a **Name** (how the app is called in the Dock and Finder, for example “Claude Work”) and an **Icon label**
   (up to 4 characters, for example “Work”); the icon in the window changes as you type. Click **Create**. Building
   usually takes 1–3 minutes; then click **Install**, and the new app opens.
7. Sign in to the other account in the new app’s window.

### What macOS may ask

- **“Move ClaudeMultiAcc to Applications?”** if you opened it straight from the disk image or the Downloads folder:
  click **Move**. From there it can build clones and open at login.
- **App Management:** if macOS asks to let ClaudeMultiAcc manage or modify apps, or says it was prevented from
  doing so, allow it (**System Settings → Privacy & Security → App Management**). This is how it installs and
  updates the clones in Applications.
- **“Claude wants to use … Claude Safe Storage in your keychain”** when a new clone starts: enter your Mac login
  password and click **Always Allow**. Each clone keeps its own encrypted sign-in. This can come back after Claude
  updates.
- Nothing is asked for signing: the certificate for clones is made quietly on your first **+ Add**.
- Each clone is a separate app for macOS, so the usual prompts (notifications, folders, microphone) appear for it
  separately.

**Signing in to a new clone works by itself.** Google and e-mail sign-in links come back to Claude as `claude://`
links, and macOS opens those in whichever Claude app was opened last (every Claude app claims them when it starts).
While a new (or signed-out) clone waits for you to sign in, ClaudeMultiAcc briefly takes these links: sign-in links go
to that clone, every other link goes on to the main Claude, and once the clone is signed in, the links go back to the
main Claude until another Claude app is opened and claims them again. The wait lasts about 30 minutes
after you last opened or switched to the clone; if more time has passed, switch to the new app and start signing in
again.

## Everyday use

The menu shows your Claude apps in a grid: the official Claude first, then your clones, and **+ Add** last. Below it
are **Open at Login** and **Quit**. You can open the apps from here or, as usual, from the Dock or Applications.

- **Check for Claude updates.** The ↻ button at the top right of the menu asks Anthropic for a newer Claude right now
  (ClaudeMultiAcc also checks a minute after it starts and then every 6 hours). Next to it you see what is going on:
  “Checking for Claude updates…”, “Downloading Claude 3.1700.0 — 42%”, “No Claude updates — you have 3.1623.3”. A new
  version (about 270 MB) is downloaded, checked against Anthropic’s signature and kept in ClaudeMultiAcc’s data folder;
  the official Claude is not changed and does not need to be opened. If something goes wrong after you click ↻, a
  window says what happened.
- **Updates.** When a newer Claude is there and some clones are behind, the menu bar icon gets a red dot, those clones
  get a blue arrow, and a bar on top says, for example, “New version 3.1700.0 — for Work and Lab” with
  an **Update** button (**Update 2** for two apps). Closed clones are updated right away. Open ones are quit after you
  confirm (“Restart and update?”, with **Don’t ask again**), updated and opened again; unsaved text in them may be
  lost. You don’t have to click at all: a closed clone updates by itself, an open one as soon as you quit it.
- **Click an app’s icon** for its actions: **Open**, **Update to …** (only when there is one), **Edit…**,
  **Reinstall…**, **Show in Finder** and **Delete “…”…**. The official Claude only has **Open** and **Show in Finder**.
  With the keyboard, ⌥Return on an icon opens the app right away.
- **Edit…** opens the same window as **+ Add** with the **Name** and **Icon label** filled in; click **Save**. A new
  name also renames the app in Applications (if it is pinned in the Dock, pin it again). An open clone closes for a
  few seconds and reopens. You stay signed in: the sign-in lives in the clone’s profile folder, which never changes,
  just like its bundle id.
- **Reinstall…** opens the same window; if you change nothing, its button reads **Reinstall**. It builds the clone
  again from the newest Claude on this Mac: same name, label and sign-in, fresh icon. Use it for clones made by older versions of
  ClaudeMultiAcc, whose icons may show a grey frame in the Dock. An open clone closes for a few seconds and reopens.
- **Old icon in the Dock.** After **Edit…** or **Reinstall…** the Dock may keep showing the old icon: macOS caches the
  icons of pinned apps. So when it is done, the window offers **Refresh Dock**, which restarts the Dock: it takes a
  second, and no windows close. Nothing restarts the Dock unless you click that button.
- **A name used before.** If you add an app with the name of one you deleted earlier and its sign-in is still on this
  Mac, the window asks: **Sign in as before** (the new app opens signed in, with the old settings) or **Start fresh**
  (the old sign-in goes to the Trash).
- **Delete “…”…** asks what to remove and shows the real sizes:
  - **App only — size**: the app leaves Applications; its sign-in, settings and cache stay, so adding an app with
    the same name again opens it already signed in;
  - **Everything — size**: the app together with its sign-in, settings, cache and local files on this Mac.

  Click **Delete**. An open clone is quit first. Everything removed goes to the **Trash**, nothing is erased. Your
  chats and projects stay in your account on claude.ai. The main Claude and your other apps are not touched.
- **Open at Login** starts ClaudeMultiAcc when you log in. It works when the app is in Applications; if macOS wants
  your approval, System Settings opens at Login Items.

## Updating ClaudeMultiAcc

Once a day the app asks GitHub whether a newer release exists (see [Privacy and network](#privacy-and-network)). When
there is one,
the bottom of the menu says **ClaudeMultiAcc … is available** with a **Download** button that opens the
release page. Download the new `.dmg`, quit ClaudeMultiAcc (menu → **Quit**), drag the new app onto Applications and
choose **Replace**, then open it (allow it once more as in step 4). Your clones, their sign-ins and the signing
certificate stay.

## Removing

1. In the menu, delete the clones you no longer want (**Delete “…”… → Everything** also removes their data), and
   turn off **Open at Login** (or remove ClaudeMultiAcc in **System Settings → General → Login Items & Extensions**).
2. Quit ClaudeMultiAcc and drag it from Applications to the Trash.
3. Optional: delete its data and logs, `~/Library/Application Support/ClaudeMultiAcc` and
   `~/Library/Logs/ClaudeMultiAcc`. The data folder also holds the signing certificate for clones.

Clones you keep go on working, but nobody updates them any more. The official Claude is never changed.

If you installed the optional update LaunchAgent (see [The `cmacc` helper](#the-cmacc-helper)), remove it as well:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.imaxzone.ClaudeMultiAcc.update-watcher.plist
rm ~/Library/LaunchAgents/com.imaxzone.ClaudeMultiAcc.update-watcher.plist
```

If you ever ran `scripts/signing-setup.sh`, its “ClaudeMultiAcc Local Signing” certificate is in your login keychain;
you can delete it in Keychain Access.

## What it never does

- Never reads or stores your passwords, tokens or cookies, and never changes Claude’s own settings. To tell whether a
  new clone is signed in, it reads only two fields of that clone’s `config.json`. The one secret it keeps is its own:
  the random password it generated for its signing keychain, in `signing/keychain-password` (see
  [Privacy and network](#privacy-and-network)).
- Never modifies the official Claude app; it only copies it.
- Never adds anything to your login keychain: the certificate for clones lives in a keychain file of its own.
- Takes over `claude://` links only while a new clone waits for sign-in, and hands them to the official Claude
  afterwards (and when it quits). The rest of the time it leaves them alone: they belong to the Claude app opened last.
- Never lets macOS offer the backup copies it keeps after updates (in **Open With** or for links): it unregisters them.
- Never quits an app without asking first (unless you chose **Don’t ask again**). What you delete from the menu goes
  to the Trash; the only files it erases for good are its own working files: temporary build copies, the temporary
  files of the signing setup, old backups in its data folder, Claude versions it downloaded once they are superseded,
  and old rotated logs.
- Makes no network requests except the daily release check and the Claude update check.

## For developers

### Build from source

Needs Xcode 27 (Swift 6.4) on an Apple Silicon Mac with macOS 26 or newer. SwiftPM only, no `.xcodeproj`.

```bash
git clone https://github.com/imaxzone/ClaudeMultiAcc.git && cd ClaudeMultiAcc
swift test
scripts/install.sh --link-cli   # build, install into ~/Applications, link ~/.local/bin/cmacc
scripts/install.sh --restart    # rebuild and restart a running copy
scripts/release.sh              # dist/: ClaudeMultiAcc.app, .zip and .dmg with .sha256 files (ad hoc signed)
```

- Build products one per command (`swift build -c release --product ClaudeMultiAcc`, then `cmacc`, then
  `CloneLauncher`): with several `--product` flags this toolchain builds only the last one.
- `scripts/bundle-app.sh` only assembles `dist/ClaudeMultiAcc.app`. The version comes from `VERSION`; the build number
  is the commit count, or 0 when building from a source archive without git (override with `BUILD_NUMBER`).
- Keep one copy: a release copy in `/Applications` and a development copy in `~/Applications` share the bundle id, and
  the one started later quits in favour of the one already running.
- Signing: the app creates its own certificate on the first **+ Add**. `scripts/signing-setup.sh` is the older,
  optional way: it puts the certificate into your login keychain (and asks for your password); a certificate made
  that way is used instead. Installed clones are never signed ad hoc (an ad hoc signature would cost them their
  permissions at every update).
- Releases: pushing a tag `v<VERSION>` runs `.github/workflows/release.yml`, which tests, builds with
  `scripts/release.sh` and attaches the `.dmg`, `.zip` and checksums to a GitHub release.
- App icon: the Liquid Glass source is `assets/AppIcon.icon` (open it in Icon Composer). After editing it, run
  `scripts/make-app-icon.sh` (needs Xcode 26+) and commit `assets/AppIcon/`; building the app only copies those files.

### The `cmacc` helper

The command-line helper lives inside the app, `ClaudeMultiAcc.app/Contents/Helpers/cmacc`
(`scripts/install.sh --link-cli` links it as `~/.local/bin/cmacc`). `cmacc --help` lists every command.

| Command | What it does |
|---|---|
| `cmacc instances list [--json]` | The list of apps (`instances.json`) |
| `cmacc instance verify <app>` | Checks a clone: signature, ids, entitlements, Anthropic’s frameworks untouched |
| `cmacc update check [--apply-when-idle]` | What the updater would do now; with the flag it also rebuilds closed clones |
| `cmacc agent print\|install --kind update-watcher` | An optional LaunchAgent that rebuilds clones while the menu app is not running |
| `cmacc route --dry-run <url>` | Where a `claude://` link would go right now; opens nothing |
| `cmacc scheme owner` | Which app handles `claude://` links right now |
| `cmacc version` | The version |

- `agent install` only writes the plist (after asking) and prints the `launchctl bootstrap` command that loads it.
  Its default `--app` is `~/Applications/ClaudeMultiAcc.app`; pass `--app /Applications/ClaudeMultiAcc.app` for a
  copy installed from the `.dmg`.
- Launch at login is the menu switch (`SMAppService`). `cmacc agent install --kind app` is retired and only says so.
  If an old LaunchAgent of that kind is still installed, the switch says so; click it once to move to the login item
  (the old plist goes to the Trash).
- The badge is part of the clone’s icon, so `cmacc instance icon` is retired as well: to change a label, use
  **Edit…** in the menu. A clone built by an older version gets the new icon at its next rebuild, or right away with
  **Reinstall…**.

### Logs

- `~/Library/Logs/ClaudeMultiAcc/`: `updates.log` (every update decision), `launcher-<name>.log` (each clone’s
  launcher), `agent-update.log` (the optional LaunchAgent).
- Everything else, including each `claude://` routing decision (links are redacted):
  `/usr/bin/log show --last 10m --predicate 'subsystem == "com.imaxzone.ClaudeMultiAcc"'`.

### Privacy and network

ClaudeMultiAcc makes two kinds of network requests, both without cookies or credentials:

- **Its own release check**: at most once a day, an anonymous `GET` of the latest release of
  github.com/imaxzone/ClaudeMultiAcc from the GitHub API (`api.github.com`, `…/releases/latest`). The answer is cached
  in `~/Library/Application Support/ClaudeMultiAcc/release-check.json`. To turn it off, start the app with
  `CMACC_NO_UPDATE_CHECK=1`, for example `open --env CMACC_NO_UPDATE_CHECK=1 -a ClaudeMultiAcc`, or run
  `launchctl setenv CMACC_NO_UPDATE_CHECK 1` before it starts (this lasts until you log out).
- **The Claude update check**: a minute after start, every 6 hours and when you click ↻, a `GET` of Anthropic’s public
  Claude Desktop update feed, the same one Claude itself uses:
  `https://api.anthropic.com/api/desktop/darwin/arm64/squirrel/update?device_id=…&version=…&os_version=…`. It sends a
  random id made once by ClaudeMultiAcc (kept in `claude-update.json`, not Claude’s own), the newest Claude version on
  this Mac, the macOS version and `User-Agent: ClaudeMultiAcc/<version>`; nothing about your accounts. When the feed
  offers a newer version, the full archive is downloaded only from `https://downloads.claude.ai/` and kept only if its
  size and SHA-256 match the feed and the app inside is signed by Anthropic (Team ID `Q6L2SF6YDW`) with the expected
  bundle id and version; an archive that fails these checks is not downloaded again automatically (↻ retries it). It
  needs 2 GB free and keeps one version (about 630 MB) in `source/`; it is deleted once the
  official Claude is as new. To turn off the automatic checks (↻ still works), use `CMACC_NO_CLAUDE_UPDATE_CHECK=1` the
  same way as above.
- Data: `~/Library/Application Support/ClaudeMultiAcc` holds `instances.json` (the list of apps), `settings.json`,
  `signing/` (the clones’ keychain file and its random password, readable only by you and excluded from Time Machine
  backups), `backup/`, `staging/`, and `source/` with the Claude version it downloaded (hidden from Spotlight and
  from **Open With**). Each clone’s sign-in and settings are in
  `~/Library/Application Support/ClaudeProfiles/<name>`.
- The signing tradeoff: the keychain password sits next to the keychain so the app can unlock it without asking you.
  Any program running as your user could therefore read it and sign an app with the clones’ certificate, which macOS
  would treat like one of your clones. If you suspect that, delete `signing/`: the next build creates a new
  certificate, and macOS asks again for each clone’s permissions and keychain access.

## License

[MIT](LICENSE).
