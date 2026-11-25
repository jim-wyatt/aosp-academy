# Deploy and verify

This page is the device node's side of the [change loop](index.md#the-change-loop): from a published image on the build node to a verified image running on the phone. It needs the workstation set up ([Set up the workstation](../start/workstation.md)), the phone on USB with root on its stock system (Magisk), and nothing else: no AOSP tree, no WSL. On a machine that is its own build node, the same commands install the image built there; see [One machine for both](../start/build-node.md#one-machine-for-both).

Commands are shown as `./aosp-academy ...`; on Windows, run `.\aosp-academy ...`. In a shell opened with `./aosp-academy shell`, the pinned `adb` is on PATH.

## In one command

```bash
./aosp-academy deploy
```

That fetches the newest image, puts it on the phone, boots it, waits for it to set itself up, reports what it sets, and runs the development-workflow tests. With the PCs' keys built into the image and no secure lock screen on the stock system, it needs no one at the phone. It asks one question first, because it deletes the installed image's data; `--yes` (`-y`) skips the question.

| Option | Effect |
| --- | --- |
| `--no-fetch` | Install the image already in `work/device-tools/gsi/own/` instead of fetching. With no build node configured (no `work/remote-build.json`, no `--host`), `deploy` does this by itself: the image there is the one this machine built. |
| `--single-boot` | Boot the image once only; the next reboot returns to stock. Default: persistent. |
| `--keep-image` | Keep the local copy of the image after installing. |
| `--skip-device-test` | Leave out `device test` at the end. |
| `--userdata-gib N` | Size of the image's data partition (default 24). |
| `-y`, `--yes` | Don't ask before replacing the installed image. |
| `--host`, `--user`, `--repo`, `--port`, `--save`, `--streams N` | As for `fetch`, below. |

The exit code is 0 when everything passed, 1 when `device test` had failures (or you answered no), and 2 on an error. Every wait for the phone has a limit: a phone that doesn't come back within ten minutes after a reboot, or never becomes authorized, ends the run with what adb last saw and what to check. Over the network that usually means the phone rebooted out of reach. Connect it by USB to look, then run the same command again; nothing is lost by stopping there.

## Fetch

```bash
./aosp-academy fetch --host <build node> --user <ssh user> --repo <repository path on the build node> [--port N] --save   # once
./aosp-academy fetch             # copy the newest image, verified
./aosp-academy fetch --check     # only say whether a newer image is waiting
```

Which machine to pull from describes your network, not the project, so it isn't in the repository: `--save` keeps the host, user, repository path and port in **`work/remote-build.json`** (git-ignored). The build node's files are read from `<repo>/work/device-tools/gsi/own/` on it, over `scp` (OpenSSH, built into Windows 10 and later, Linux and macOS), with key login only (`BatchMode=yes`). SSH keep-alives (every 15 s, four missed) end a connection that dies silently in the VPN tunnel after about a minute instead of leaving `scp` waiting for ever.

What `fetch` does, in order:

1. **Read the remote checksum** (`system.img.sha256`). If the local `system.img` already matches, stop: up to date. With `--check`, also compare with `work/device-tools/gsi/own/deployed.sha256`, the hash of the image last deployed (deploy deletes the local copy, so "no local image" usually means "already on the phone"), and say whether something new is waiting.
2. **Pull the parts** listed in `system.img.parts` over `--streams` parallel connections (default 8, up to 32), each into a hidden file, and check each part's SHA-256. Parts that fail or mismatch are fetched again, up to three retries with a growing pause (15, 30, 45 s), because on a congested link parts fail in bursts. Verified parts are kept on failure, so running again resumes. If no parts are published, pull the single `system.img`.
3. **Join the parts** into `system.img.part`, deleting each part as soon as it is joined, so the parts and the image never both sit on disk in full.
4. **Check the joined image** against the remote SHA-256. On a mismatch nothing is replaced.
5. **Fetch the sidecars before swapping anything in:** `build.prop` (required: without it nothing is replaced) and `vbmeta.img` (if published). Then remove the previous build's copies and move the new files into place, so an old `build.prop` or `vbmeta.img` never travels with a new image into the DSU zip.
6. **Write `system.img.sha256`** beside the image and print the size, the time and the fingerprint.

The image it replaces is deleted; there is no `system.prev.img`. A fetch in parts takes about 4 minutes (16 parts, about 1.75 GB at about 6.8 MB/s), against about 13 minutes for the single file.

## Deploy, step by step

`aosp-academy deploy` (`aosp_academy/deploy.py`) runs these steps. It first checks that exactly one device is connected.

1. **Fetch** as above, unless `--no-fetch`. Then check the local `system.img` against its `system.img.sha256`; a mismatch stops the deploy ("Fetch it again").
2. **Ask** before replacing the installed image and its data (unless `--yes`).
3. **Back to stock.** If a DSU image is running, `gsi stock` disables it and reboots to the phone's own system: the DSU installer works only from there.
4. **Discard** the installed image and its data (`gsi_tool disable`, `gsi_tool wipe`).
5. **Install.** The image is wrapped in a zip with its `build.prop` and `vbmeta.img`, pushed to the phone's `Download` folder, and handed to Android's DSU installer with a `--userdata-gib` data partition. The zip on the PC is deleted as soon as it is pushed. The installer asks for the screen-lock PIN only on a phone with a secure lock screen. The CLI follows the installer's own status in logcat (`NOT_STARTED`, `IN_PROGRESS`, `READY`, or an error cause), waiting up to 30 minutes, then removes the pushed zip. Typical: `READY` 20 to 30 s after the push.
6. **Boot**, persistent (`gsi_tool enable`) unless `--single-boot`. The CLI waits for the old system to drop off USB first (so its "boot completed" isn't taken for the new system's), then for authorisation (below), then for `sys.boot_completed`. It checks that `ro.product.name` is the image's product (`aospacademy...`).
7. **Drop the local copy** (unless `--keep-image`): `system.img`, `build.prop`, `vbmeta.img` go, and the hash moves to `deployed.sha256`. The image is on the phone, and a rebuild of the same commit gives it back.
8. **Wi-Fi.** If `work/wifi.json` exists, switch Wi-Fi on and join that network, then wait up to 60 s for it to validate.
9. **First boot.** Wait up to 300 s for the first-boot service's `status` file to read `done`, read its `log`, and warn about any line that says `failed` or `did not stick`. Then wait up to 60 s more for the `charge-limit` file, which the charge-limit service writes 30 s after boot.
10. **Report** (below).
11. **Device test** (below), unless `--skip-device-test`.

### Authorisation: the Allow prompt and built-in keys

The image sets `ro.adb.secure=1`, and every fresh install starts with no authorised computer. Two cases:

- **The PC's key is built into the image** (the build node had it in `work/adb_keys`; [What's in the image](image.md#adb-authorisation-and-the-trusted-keys)): adb works from the first boot, no tap. The report's `AdbKeys` row says `built in (N keys)`. Both of this project's PCs are trusted this way.
- **Any other PC:** the phone shows *Allow USB debugging?* on the first connection after every deploy, and adb sees the phone as `unauthorized` until someone taps **Allow** (tick *Always allow from this computer*). The deploy doesn't wait silently: it prints a "Tap Allow on the phone" line and waits.

To trust a new PC without the tap, add its `adbkey.pub` line (from `~/.android/adbkey.pub` on that PC, never the private `adbkey`) to `work/adb_keys` on the build node and build again. The **stock system** keeps its own list, `/data/misc/adb/adb_keys`, filled by tapping Allow there. Every deploy, while it is on stock, adds any key from `work/adb_keys` and this PC's own key that stock doesn't have yet (`aosp-academy stock trust` does the same by hand). So a PC the image trusts is trusted on stock too, and a build node that reaches the phone only over the network is never refused when the phone reboots to stock. Before this, the build node's key had to be added to stock by hand, over a cable.

### wifi.json

A fresh DSU install has Wi-Fi off and no saved network, so the network checks in the report would fail. A private file **`work/wifi.json`** on the device node fixes that:

```json
{"ssid": "<network name>", "security": "wpa2", "passphrase": "<passphrase>"}
```

`security` is passed to the phone's `cmd wifi connect-network` (`wpa2` here; that command also takes `open`, `owe` and `wpa3`). The file is git-ignored and blocked by the pre-commit hook, and the passphrase never goes into the CLI's output. Never commit it, paste it into an issue, or put its contents in a message. Without the file the deploy skips the step, and the report says so.

The network reaches the new image through **staging** (below): the deploy doesn't need adb in the new image to join it. If the staged network doesn't validate within a minute, the deploy joins it directly instead.

### The WireGuard tunnel (optional)

With a WireGuard hub, the phone can have a tunnel of its own, so adb reaches it from any PC on the tunnel, whatever network its Wi-Fi is on. The kernel has WireGuard built in and the image ships `wg`; what's missing on a fresh install is the tunnel's configuration, which the deploy pushes after joining Wi-Fi when the device node has two private files in **`work/wireguard/`**:

- **`wg0.conf`**, in `wg setconf` format: an `[Interface]` with the phone's `PrivateKey` only (no `Address` or `DNS` lines), and the hub as `[Peer]` (`PublicKey`, `Endpoint`, `AllowedIPs`, `PersistentKeepalive = 25`, which keeps the NAT mapping open while the phone is idle).
- **`wg0.env`**, the addresses and routes: `ADDRESS4=`, `ADDRESS6=`, `ROUTES4=` and `ROUTES6=` (routes space-separated, for example the tunnel's subnet). Optional: `MTU=` (1280 suits a phone on Wi-Fi), and **`FULL=1`** with `DNS4=` and `DNS6=` (the hub's resolver) for a full tunnel, below. Write both files with LF line ends; the phone's readers strip a stray CR, but don't rely on it.

**Full tunnel.** With `FULL=1`, and `AllowedIPs = 0.0.0.0/0, ::/0` in `wg0.conf`, the image sends **all** its traffic through the hub, which has to forward and NAT it. Only three things stay off the tunnel: the encrypted packets to the hub's endpoint, the Wi-Fi network's own subnet (the router, DHCP, neighbour discovery), and the subnet of any wired network Android brings up on a USB device (a USB Ethernet adapter, or an ADALM-Pluto SDR in NCM mode), so apps can reach the device directly. DNS goes to the hub's resolver whatever server the Wi-Fi network hands out: IPv4 queries are redirected there, IPv6 queries to any other server are rejected (this kernel has no IPv6 NAT), and Private DNS is switched off. Anything leaving through the tunnel gets the tunnel address as its source. An `unreachable` route behind the tunnel's is the **kill switch**: if the tunnel goes down, traffic fails rather than leaving by Wi-Fi. Before it routes anything into the tunnel, the script waits up to two minutes for Wi-Fi's own routing table, and checks the rules that keep the hub's packets and the local subnet on Wi-Fi. If either is missing, it routes nothing into the tunnel and reports `failed`, so the phone stays reachable over plain Wi-Fi. On build 22's second boot the script ran before Wi-Fi's table existed: the tunnel's own packets looped into the tunnel, and the kill switch cut the phone off until the service was run again. While the image runs, a second service, `aospacademy_wgwatch`, keeps those two rules current: whenever a routing rule or route changes, it checks both rules and `wg0`, and sets the tunnel up again if Wi-Fi changed under it. It also adds or removes the wired networks' rules as USB devices come and go, without restarting the tunnel. It is driven by `ip monitor`, not a timer, because an idle phone suspends and timers stand still while it does. The stock system reads the same files but routes only the `ROUTES4`/`ROUTES6` subnets into its tunnel.

**Tunnel wakelock.** A suspended phone stops sending its keepalive, so the UDP mapping on the Wi-Fi router expires and nothing from the hub reaches the phone, `adb` included, until something wakes it. Disabling Doze doesn't prevent this: on battery, with the screen off, the kernel suspends anyway, and pings from the build machine every 20 s began failing about four minutes after the phone was last used (2026-11-25). So while `wg0` is up and the tunnel reports `up`, the image holds a kernel wakelock, `aospacademy_tunnel`, that keeps the CPU awake (the screen still turns off), and releases it when the tunnel goes. The setup sets it, and `aospacademy_wgwatch` keeps it right on every routing change. It costs battery unless the phone is on its charger. Turn it off with `adb shell su 0 setprop persist.aospacademy.tunnel_wakelock 0` (applied at once, kept until the next deploy), and back on with `1`. To see it: `adb shell su 0 grep aospacademy_tunnel /sys/kernel/debug/wakeup_sources` (a non-zero sixth column means held).

Make the phone's key pair on the device node (`wg genkey > work/wireguard/phone.key`, then `wg pubkey < work/wireguard/phone.key`) and give the hub only the public key. The tunnel config reaches the new image through staging too, and the image keeps it in a root-only directory (`/data/local/aospacademy-wg`) and brings the tunnel up again at every boot until the next deploy. If the staged tunnel doesn't come up, the deploy pushes it directly instead. Then, from a PC on the tunnel: `adb connect <the phone's tunnel address>:5555`.

`work/` is git-ignored and the files never belong in the repository, an issue or a message. With the phone on USB and the tunnel at once, adb lists it twice; `aosp-academy` uses the USB connection (or set `ANDROID_SERIAL` to choose).

### Staging for the first boot

A DSU install always starts the image with empty data, and Android refuses to install one DSU image from inside another, so every deploy goes through the stock system. While it's there, after discarding the old image, the deploy **stages** what the new image needs on its first boot in **`/metadata/aospacademy`**: `wifi.env` (the network from `work/wifi.json`) and `wg0.conf` and `wg0.env` (the tunnel). The metadata partition is shared by stock and the image, and a DSU install leaves it alone. The directory is root-only (700, files 600).

The image's first-boot service joins the network, installs the tunnel config, starts the tunnel, and then deletes the directory whether or not that worked, so the secrets sit there only from staging until the first boot, a few minutes. The deploy checks the directory is gone. `/metadata` isn't covered by Android's per-user encryption; the stock system's own data already holds the same Wi-Fi network. Android's `cmd wifi connect-network` takes the passphrase only as an argument, so while it runs, the passphrase is in that process's command line. Android mounts `/proc` so that apps can't see other processes; only root and the shell's process-reading group can, and the passphrase is never logged or written to a file. The direct join over adb has the same exposure.

### The report

The report reads back from the phone what the image sets. `./aosp-academy device report` prints it again at any time, for the running image (without the first-boot result, which only the deploy collects).

| Row | What it shows | Expected on a good image |
| --- | --- | --- |
| `Fingerprint` | `ro.build.fingerprint` | `Android/aospacademy_arm64/generic_arm64:...:userdebug/test-keys` |
| `Home` | the HOME role holder | `org.fossify.home` (Fossify Launcher) |
| `FirstBoot` | the first-boot `status`, and how many icon colours it set | `done failures=0; 16 icons set` |
| `Bluetooth` | the adapter and Bluetooth scanning | `off, scanning off` (on only if switched on since the deploy) |
| `DevOptions` | Developer options, Stay awake and the brightness setting | `shown=1 stay_awake=15 brightness=64` |
| `Animations` | the three animation scales | `0/0/0` |
| `LogBuffer` | `logcat -g -b main` | 16 MiB |
| `TimeZone` | `persist.sys.timezone` | `America/New_York` |
| `AospIcons` | whether the Files and keyboard icons are still in the launcher | `hidden (Files, keyboard)` |
| `ChargeLimit` | the charge-limit result file, then `blocking` now and the battery level | `upper_limit=80, blocking=...`; `blocking=1` while the battery is above the limit |
| `Network` | whether a network is validated, which hosts the captive-portal probes used, and the last NTP server | `validated; probes to connectivitycheck.grapheneos.network; NTP ntp://pool.ntp.org` |
| `AdbKeys` | how many keys `/product/etc/security/adb_keys` holds | `built in (N keys)`, or `none (each PC needs the Allow tap)` for an image built without keys |
| `Battery` | level, charging status, health, temperature and power source, from `dumpsys battery` | health `good`; on the cable above the limit: `not charging`, power `USB` |
| `Tunnel` | the WireGuard tunnel's state and the age of its last handshake | `up <address>, handshake Ns ago`, or `none` without `work/wireguard` |
| `AdbTcp` | whether adbd listens on TCP (`persist.adb.tcp.port`) | `listening on 5555` |
| `CrashLog` | fatal entries in the crash buffer | `empty` |
| `DataFree` | free space in `/data` | about 22 GB with the default 24 GB partition |

The `ChargeLimit` row reads only two named files, `blocking` and the battery's `capacity`: never bulk-read `/sys/module/*/parameters` on this phone, because it panics the kernel ([What's in the image](image.md#the-charge-limit)).

### device test

`./aosp-academy device test` exercises every development workflow the docs teach, end to end, on whatever system the phone runs, and leaves nothing behind. The deploy runs it last. The exit code is the number of failed checks. `--skip frida,mirror` (comma-separated areas) leaves areas out.

| Area | Checks |
| --- | --- |
| `device` | identity (model, product, build type, Android version); which system is running; SELinux enforcing; boot completed |
| `root` | a root shell (Magisk's `su -c` on stock, AOSP's `su 0` in an image) |
| `logs` | logcat reads (more than 50 lines); the buffer size; `dumpsys -l` lists more than 100 services |
| `native` | an aarch64 binary built with the pinned NDK, pushed, run on the phone, removed |
| `app` | an APK built with the pinned SDK tools alone (javac, d8, aapt2, zipalign, apksigner; no Gradle), installed, launched, its log line read back, uninstalled |
| `debug` | `adb root` and back to an unprivileged adbd (userdebug images only); how many processes accept a debugger (JDWP) |
| `trace` | a 2-second Perfetto trace, pulled, checked and deleted |
| `frida` | `frida-server` started, `frida-ps -U` sees more than 20 processes, stopped (needs root) |
| `mirror` | `scrcpy --list-displays` reaches the device (opens no window) |

On an image, all 15 checks pass. Each workflow is explained under [Develop apps](../apps/index.md).

## What a deploy wipes

A deploy **discards the installed image and its userdata**: apps you installed, files, settings changed on the phone, a charge limit set with `setprop`, saved Wi-Fi networks. The new image starts from scratch, and the first-boot service sets it up again. The phone is a test target, not a store: keep nothing on the image you can't recreate.

What it doesn't touch: the stock system on the phone's own slot, its data, root on it, the bootloader. DSU runs the image from files in `/data`; nothing is flashed.

## Living with the image

The image is the phone's everyday system until you switch back. A plain `adb reboot` comes back into it.

```bash
./aosp-academy gsi status          # which system is running, and what DSU holds
./aosp-academy gsi stock           # to the phone's own system; the image stays installed, with its data
./aosp-academy gsi boot            # back into the image, its data as you left it (--single-boot: once)
./aosp-academy device test         # are the development workflows fine right now?
```

A reboot into the image takes about 45 s, and either switch about 55 s. The image's data and its first-boot state survive the round trip through stock.

## Rolling back to an earlier image

A rollback is a deploy of an earlier image, so it wipes the image's data like any other.

- **From a rebuild:** request a build of the last good commit (the [current image](validation.md#current-image) names its commit, and the `baseline-N` git tags mark validated images: `git tag -n1 'baseline-*'`), then `./aosp-academy deploy` as usual.
- **From a saved copy:** put the earlier `system.img` and its own `build.prop` (and its `vbmeta.img`, if it had one) in `work/device-tools/gsi/own/`, and remove the other build's `vbmeta.img` if the earlier one had none, so nothing from another build is packed with it. Either write a matching `system.img.sha256` (`<sha256>  system.img`) or remove the old one, because the deploy refuses an image that doesn't match the checksum beside it. Then `./aosp-academy deploy --no-fetch`.

Save a copy of the last validated `system.img` and `build.prop` before a risky change: the build node keeps only its newest image.

## Going back to stock

`./aosp-academy gsi stock` disables the running image and reboots into the phone's own Motorola system. The image stays installed, and `gsi boot` returns to it with its data. To remove the image as well:

```bash
./aosp-academy gsi stock      # if the image is running
./aosp-academy gsi discard    # from stock: remove the image and its userdata
```

`discard` refuses while an image is running. After it, `gsi status` reads `normal` and the phone is as it was before the first deploy. If an image ever won't start at all, the DSU loader falls back to the stock system after a failed boot (with `--single-boot`, holding Power for a restart also returns to stock); from there, `gsi discard` cleans up, and a deploy puts a working image back.

The `gsi` command also boots Google's pinned GSI (`gsi download --accept-google-gsi-terms`, then `gsi install` without `--image`), which is how a new Android release is tested on this vendor before anything is ported ([Move to a new AOSP release](tag-moves.md)). [DSU](../device/dsu.md) explains DSU itself, and [The stock system](../device/stock.md) the system you return to.
