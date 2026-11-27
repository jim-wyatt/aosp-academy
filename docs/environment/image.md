# What's in the image

`aospacademy_arm64` is AOSP's own arm64 Generic System Image (GSI) with a short list of changes on top. This page goes through the list, item by item, and says why each item is there. The product tree `image/product/aospacademy/gsi/` in the repository is the whole description; nothing about the image lives only on the build node.

If you are developing apps and want to know what the image gives you (root, JDWP, logs, defaults), [The image for app developers](../apps/the-image.md) is the shorter version. The decisions behind the bigger choices are in [Decisions](../reference/decisions.md).

## What you can change, and what you can't

The image replaces the phone's **system** side: the framework, the system services, the launcher, Settings, the system apps, the system half of the SELinux policy, and the build type. It is a `userdebug` build, the engineering build type, where `adb root` works and a debugger can attach to any process.

It does not replace the **vendor** side: the kernel, the vendor HALs (hardware abstraction layers: the vendor's drivers for the camera, radio, sensors and so on), the firmware and the modem. They stay Motorola's, behind the Treble interface, the fixed boundary between system and vendor that lets a generic system run on this phone at all (see [Partitions and slots](../concepts/partitions-and-slots.md)). The GSI's hardware gaps, such as two cameras of three, are limits of that interface rather than of this build. A full device port would be a different and much larger project.

The vendor layer on this phone is Android 13's (`ro.vndk.version=33`, VINTF target level 7), under an Android 17 system. That gap is what makes every [tag move](tag-moves.md) start with a test.

## The base: AOSP's arm64 GSI

The image is built from the AOSP release tag pinned in `toolchain.json` (`deviceTools.aosp.tag`), **`android-17.0.0_r1`** (build `CP2A.260605.016`, security patch 2026-06-05). That is the same Android 17 release as Google's GSI binary `CP2A.260605.012`, pinned as `deviceTools.gsi`, which boots on this phone with the full hardware list. So the starting point of every build is a system shown to run on this vendor. Moving to a later release is in [Move to a new AOSP release](tag-moves.md).

The lunch target is **`aospacademy_arm64-trunk_staging-userdebug`** (`deviceTools.aosp.lunch`): the product `aospacademy_arm64`, the release configuration `trunk_staging`, the build type `userdebug`. `AndroidProducts.mk` also offers an `-eng` variant.

The image is signed with AOSP's public test keys, not Google's. On this unlocked phone the DSU installer accepts a test-keyed image, because `gsid` does not enforce trusted keys in the `orange` (unlocked) boot state. Never ship or publish a test-keyed image as if it were a release. AOSP is Apache-2.0; Google's GSI terms apply to Google's binary, not to your own build, and nothing from Motorola's vendor partition is part of what is built or distributed. The image is about 1.8 GB.

## The product makefiles

AOSP describes what goes into an image with *product makefiles*: `.mk` files that set variables (`PRODUCT_PACKAGES`, properties, files to copy) and inherit other makefiles. This project has four, in `image/product/aospacademy/gsi/`:

| File | What it is |
| --- | --- |
| `AndroidProducts.mk` | Registers the product and its lunch choices. |
| `aospacademy_arm64.mk` | Upstream's `build/make/target/product/aosp_arm64.mk`, with three changes: the product-partition app set comes from `aospacademy_product.mk` instead of `aosp_product.mk`; the Virtualization (AVF) product packages are not inherited; and the settings `aosp_arm64.mk` keeps behind its `ifeq (aosp_arm64,$(TARGET_PRODUCT))` guard are applied unconditionally (a derived product has a different name, so it must repeat them, as AOSP's own `aosp_arm64_fullmte.mk` does). Below that come this project's own settings, each with a comment. |
| `aospacademy_product.mk` | Upstream's `aosp_product.mk`, kept line for line except for what the Fossify suite replaces: it inherits `aospacademy_handheld_product.mk`, inlines `telephony_product.mk` without Dialer, drops `messaging`, and leaves out PhotoTable. |
| `aospacademy_handheld_product.mk` | Upstream's `handheld_product.mk` without Calendar, Camera2, Contacts, DeskClock, Gallery2, Music, QuickSearchBox and Browser2. LatinIME stays. |

Copies rather than edits, because neither make nor Soong can subtract a package another makefile adds: the only way to leave out an app is to not inherit the file that adds it, and to repeat the rest. The copies are kept line for line with upstream so a diff shows exactly what changed, which is what a [tag move](tag-moves.md) checks.

The **system partition** is otherwise the stock GSI's, from upstream's `generic_system.mk` and the files it inherits, unchanged except for the patches below. One rule follows from that: the GSI forbids adding properties to the system partition (its artifact-path requirement, in `generic_system.mk`), so every property this project sets goes in `PRODUCT_PRODUCT_PROPERTIES`. That lands in the product partition's `build.prop` (under `/system/product/etc/` in a GSI), which init reads just the same, and last, so its values win.

## The Android.bp mirror

AOSP builds the GSI's `system.img` from a Soong module (`android_system_image`), and a check called **filelistdiff** (`build/make/tools/filelistdiff`) stops the build if that module's dependency list differs from what the product makefiles install. Upstream's module, `aosp_system_image`, and its defaults, `android_gsi_defaults` (both in `build/make/target/product/gsi/Android.bp`), name the AOSP apps the Fossify suite replaces. Soong lists cannot be subtracted from either.

So `image/product/aospacademy/gsi/Android.bp` **mirrors** them: `aospacademy_gsi_defaults` is `android_gsi_defaults` without Browser2, Camera2, Dialer and messaging, and `aospacademy_system_image` is `aosp_system_image` without Calendar, Contacts, DeskClock, Gallery2, Music, QuickSearchBox and PhotoTable, plus this project's modules (the overlays, the Fossify apps, the first-boot service and its init file). `aospacademy_arm64.mk` points the build at it with `PRODUCT_SOONG_DEFINED_SYSTEM_IMAGE := aospacademy_system_image`.

The mirror is the part most likely to drift when the tag moves, and filelistdiff is what tells you: it names every module that is in one list and not the other. For Android 17 the mirror carries seven entries upstream added there (`preinstalled-packages-gsi-system-ext.xml`, `preinstalled-packages-base-product.xml`, `wificond`, `hwservicemanager`, `android.hidl.allocator@1.0-service`, `preinstalled-packages-platform-telephony-system-ext.xml`, `preinstalled-packages-telephony-system-ext.xml`) and `AvatarPicker` in the group upstream moved it to; each is marked in the file. The VNDK APEXes `com.android.vndk.v31` to `v34` stay, and `v33` is the one this vendor needs.

To build its product and system_ext `build.prop` files the same way the GSI does, the mirror needs a Soong module that upstream makes visible only to the GSI's own directory. That is the reason for the `build/soong` patch below.

## The Fossify suite and the roles

The **Fossify** apps (GPL-3.0, the maintained successor of Simple Mobile Tools, built and signed by Fossify and distributed by F-Droid) are the only apps added on top of AOSP. They replace the AOSP apps one for one, and add a few:

| Fossify app | Replaces |
| --- | --- |
| Launcher | Launcher3's home screen (Launcher3QuickStep stays, below) |
| Gallery | Gallery2 |
| Calendar | Calendar |
| Contacts | Contacts |
| Clock | DeskClock |
| Phone | Dialer |
| Messages | messaging |
| Music Player | Music |
| Camera | Camera2 |
| Calculator, File Manager, Documents, Notes, Voice Recorder, Paint, Keyboard | nothing: added (the makefiles remove no other AOSP app for them) |

QuickSearchBox is left out too, because nothing needs it.

Every APK is pinned in `toolchain.json` by SHA-256 and signing certificate, checked against F-Droid's signed index when it was pinned, and downloaded on the build node by `./aosp-academy image inputs`. `apply-local.sh` copies them into the tree from the list in `prebuilt/apks.txt`; no APK is ever committed. `prebuilt/Android.bp` imports each one with `preprocessed: true` and dex pre-optimisation off, so Soong checks the alignment and copies the APK unmodified, with the publisher's signature intact.

Nothing updates the apps on the device: there is no app store in the image, so a new version means a new pin and a new image. There is also **no web browser**, by design: Browser2, AOSP's WebView test shell, stays out, and WebView still renders web content inside apps (it is AOSP's, from the tag, and ages with it). Links to `https://` pages resolve to nothing. The F-Droid client is not in the image either; it stays pinned for the stock system.

Some AOSP apps stay on purpose:

- **Launcher3QuickStep**: SystemUI binds its quickstep service for gesture navigation and recents. It is not the home screen: the first-boot service gives the HOME role to Fossify Launcher (build 21 gave it to Quickstep). The two answer HOME with equal priority, so without an explicit role holder Android shows a chooser; a `preferred-apps` file isn't reliably honoured.
- **LatinIME** beside Fossify Keyboard: a working keyboard must never depend on a prebuilt.
- **DocumentsUI**: the system file picker behind every open, get-content and save dialog, Fossify's included. Only its launcher icon is hidden.
- **Settings**, and everything delivered as a Mainline module.

The **DIALER** and **SMS** roles go to Fossify Phone and Fossify Messages through the framework overlay (below); the **HOME** role, through the first-boot service.

## Removed: PhotoTable and AVF

- **PhotoTable** (a photo screensaver) is left out of the product makefiles and the mirror, which this project already maintains.
- **The Virtualization (AVF) product packages** are not inherited (`packages/modules/Virtualization/apex/product_packages.mk`), and `com.android.compos` is out of the image's dependencies. This SoC has no pKVM, the hypervisor AVF needs (no `/dev/kvm`, no `ro.boot.hypervisor.*`), so CompOS, the virtualization feature file and the AVF properties would be dead weight. `com.android.virt` itself stays, because `base_system.mk` installs it and its `framework-virtualization` jar is on the classpath; without `PRODUCT_AVF_ENABLED` it builds its variant for devices without AVF.

The other unused system apps (BasicDreams, `com.android.egg`, Bips, PrintSpooler, HtmlViewer, BookmarkProvider, CallLogBackup, WallpaperBackup) stay. They live on the system partition, and removing them would mean mirroring about 600 lines of upstream system-image definitions and re-checking them on every tag move, which costs more than the space is worth ([Decisions](../reference/decisions.md)).

## The overlays

An **overlay** (a runtime resource overlay, RRO) is a small package with no code that replaces resource values of another package at runtime, so a default can change without patching the package itself. The image has two, both static (enabled at boot, not switchable in Settings) and both on the product partition at priority 201.

**`AospAcademyFrameworkOverlay`** (`overlay/`) targets the framework (package `android`):

| Resource | Value | Effect |
| --- | --- | --- |
| `config_defaultNightMode` | `2` | Dark theme by default. |
| `config_navBarInteractionMode` | `2` | Gesture navigation by default. |
| `config_defaultDialer` | `org.fossify.phone` | Fossify Phone holds the DIALER role. |
| `config_defaultSms` | `org.fossify.messages` | Fossify Messages holds the SMS role. |
| `config_ntpServers` | `ntp://pool.ntp.org` | Network time from the NTP Pool Project instead of `time.android.com`. |
| `default_wallpaper` (drawable) | the project's wallpaper | Material You derives the system colours from it. |

**`AospAcademyNetworkStackOverlay`** (`overlay/networkstack/`) targets the `NetworkStackConfig` overlayable of `com.android.networkstack`. It sends the **captive-portal probes** (the HTTP requests Android makes to decide whether a network really reaches the internet) to GrapheneOS's public endpoints, which answer the same `204` as Google's for any client:

| Resource | Value |
| --- | --- |
| `config_captive_portal_http_url` and `config_captive_portal_http_urls` | `http://connectivitycheck.grapheneos.network/generate_204` |
| `config_captive_portal_https_url` and `config_captive_portal_https_urls` | `https://connectivitycheck.grapheneos.network/generate_204` |
| `config_captive_portal_fallback_urls` | `http://grapheneos.online/gen_204` |

Both the single URLs and the arrays are set because NetworkMonitor reads the arrays first, and the phone's vendor overlay (`NetworkStackResOverlay`, priority 7) fills them with Google's hosts. Setting only the single URLs leaves the probes on Google's hosts. The reason for leaving Google's endpoints is the project's policy of avoiding Google services in the image as far as practical ([Decisions](../reference/decisions.md)).

## Properties the image sets

All in `PRODUCT_PRODUCT_PROPERTIES` in `aospacademy_arm64.mk`:

| Property | Value | Why |
| --- | --- | --- |
| `debug.sf.nobootanimation` | `1` | No boot animation: SurfaceFlinger never starts the `bootanim` service, and the screen stays on the bootloader's splash until the lock screen. The makefile shows the one-line alternative for shipping your own `bootanimation.zip`. |
| `persist.sys.timezone` | `America/New_York` | Without a SIM, the telephony time-zone suggestion isn't applied (the US has several offsets), and AOSP without Google's services has no location time-zone provider, so the phone would otherwise start in GMT. A zone chosen later in Settings is stored in `/data` and wins. Change the default here for another region. |
| `persist.aospacademy.charge_limit` | `80` | The charge limit, below. |
| `persist.debug.dalvik.vm.jdwp.enabled` | `1` | JDWP for every app, below. |
| `ro.adb.secure` | `1` | adb authorisation on, below. |

## The WireGuard tunnel

The kernel (5.15 GKI) has WireGuard built in, and the image adds **`/product/bin/wg`**, built from wireguard-tools (AOSP has no copy): `toolchain.json` pins the release by tag and commit, `aosp-academy image inputs` clones it and checks the commit, and `apply-local.sh` copies its `src/` next to `image/product/aospacademy/gsi/wireguard/Android.bp` in the tree (module `aospacademy_wg`, GPL-2.0-only, its licence text alongside). The source is never in this repository.

The first-boot script's **`wireguard` mode**, started by the `aospacademy_wireguard` init service after boot, brings up `wg0` when `/data/local/aospacademy-wg/` holds a config (`wg0.conf` and `wg0.env`, pushed by the deploy): `ip link add wg0 type wireguard`, `wg setconf`, the addresses, then the routes in a table of their own (1999) with a rule at priority 9000, because Android routes by policy per network and would otherwise not send the tunnel's subnets to `wg0`. With `FULL=1` in `wg0.env` it builds a **full tunnel** instead: a rule at 8990 sends the encrypted packets to the hub's endpoint by Wi-Fi (`lookup wlan0`), one at 8995 keeps the Wi-Fi subnet local (`lookup wlan0 suppress_prefixlength 0`), one per wired network at 8996 does the same for each Ethernet network Android brings up (`lookup eth0 suppress_prefixlength 0`, for a USB Ethernet adapter or an ADALM-Pluto in NCM mode), and one at 9000 sends everything else to table 1999, which holds `default dev wg0` and, behind it, `unreachable default metric 9999` as the kill switch. NAT rules (chains `aa_snat` and `aa_dns`) give tunnel traffic the tunnel's source address and send IPv4 DNS to the hub's resolver; `aa_dns6` rejects IPv6 DNS to anything else. Each run first removes what an earlier run set, so the files on the phone always describe its state exactly. Its result goes to `status` in that directory (`up <address>, all traffic` for a full tunnel). Without a config it exits at once, so an image without a tunnel behaves as before. The private key never leaves the device node except over USB to that root-only directory. The script's **`wireguard-watch` mode**, run by the `aospacademy_wgwatch` init service for as long as the image runs, repairs the full tunnel when Wi-Fi changes under it: on every routing change (`ip monitor rule route`) it checks the 8990 and 8995 rules and `wg0`, and runs the `wireguard` mode again if one is missing or no longer names Wi-Fi's table. With Wi-Fi down it waits. On the same events it keeps the 8996 rules matching the wired networks that exist: when a USB network device is plugged in, its rule is added, and when it is unplugged the leftover rule, which then names a table number instead of `eth0`, is removed. That touches 8996 only and never restarts the tunnel, so adb over the tunnel stays up.

The **tunnel nudge** keeps the phone reachable behind a router that renumbers its UDP mapping (see [deploying](deploying.md)). **`/product/bin/aospacademy-tunnelnudge`** (`tunnelnudge/`, module `aospacademy_tunnelnudge`, plain C) waits on a `CLOCK_BOOTTIME_ALARM` timerfd with `EPOLLWAKEUP`, so the alarm wakes a suspended phone and keeps it awake until the program waits again. On each alarm it takes the kernel wakelock `aospacademy_nudge` for 5 seconds and runs the script's **`tunnel-nudge` mode**. That mode sets each peer's persistent keepalive to 0 and back to its value, because the kernel sends a keepalive at once only when it goes from off to on. The init service `aospacademy_tunnelnudge` passes the interval from `persist.aospacademy.tunnel_nudge` (120 seconds unless set, 30 at least, `0` off) and restarts when it changes.

## ADB authorisation and the trusted keys

**`ro.adb.secure=1`** turns adb authorisation on, as on a user build: a PC must be allowed on the phone's screen ("Allow USB debugging?") before adb works. Without it, any USB host would get a root-capable shell on this userdebug image. The GSI's system_ext `build.prop` sets `ro.adb.secure=0` (`build/make/target/board/gsi_system_ext.prop`); init loads the product partition's `build.prop` last, so the product value wins.

Every DSU install starts with empty userdata and so with no `/data/misc/adb/adb_keys`: without help, each deploy would need a tap. The help is **`PRODUCT_ADB_KEYS`**. On the build node, a git-ignored file **`work/adb_keys`** holds the public keys of this project's own PCs, one `adbkey.pub` line each (`QAAAA... user@host`; never the private `adbkey`). `apply-local.sh` checks its format and copies it to `device/aospacademy/gsi/adb_keys` in the tree, and the makefile sets `PRODUCT_ADB_KEYS := $(wildcard device/aospacademy/gsi/adb_keys)`. The keys are installed at `/product/etc/security/adb_keys` (which `/adb_keys` links to), and adbd trusts that list alongside `/data/misc/adb/adb_keys`, so those PCs need no tap after a deploy. AOSP keeps the file for userdebug builds (the release flag `RELEASE_BUILD_PURGE_PRODUCT_ADB_KEYS` is false there).

Without `work/adb_keys` the image trusts no PC in advance. No key is ever in the repository, which is public. An image built with keys is specific to those machines: don't pass it on.

## JDWP for every app

`persist.debug.dalvik.vm.jdwp.enabled=1` makes every app process open JDWP (the Java Debug Wire Protocol), so Android Studio's *Attach debugger to Android process* and `adb jdwp` reach any process, `system_server` and SystemUI included, without a debuggable APK. Zygote reads the property once at start, and only on a userdebug build; a user build ignores it. It is a `persist.*` default, so setting it to `0` on the phone and rebooting turns it off. It gives no access beyond what `adb root` already gives an authorised PC. Without it, `adb jdwp` lists no processes at all. [Debugging](../apps/debugging.md) shows how to use it.

## The first-boot service

Some things can't be set from a read-only partition: a role holder, a global setting, an app's icon colour. The **first-boot service** sets them on the phone. It is `aospacademy-firstboot`, a shell script (`firstboot/aospacademy-firstboot.sh`, built as an `sh_binary` into `/product/bin/`), which `init.aospacademy.rc` starts once `sys.boot_completed` is set, as root, in the `su` SELinux domain (`seclabel u:r:su:s0`), which exists only on userdebug builds.

It runs on every boot, but each step checks a marker file in its **state directory, `/data/local/aospacademy-firstboot/`**, before it acts. So each step happens once, later boots cost about a second, and a choice you make later (another launcher, another icon colour) is kept. A step that fails is logged and retried on the next boot.

0. **Staged provisioning.** If `/metadata/aospacademy` exists (left by the deploy on the stock system, see [staging](deploying.md#staging-for-the-first-boot)), it joins the Wi-Fi network in `wifi.env` (`cmd wifi connect-network`; the passphrase is never logged), copies `wg0.conf` and `wg0.env` to `/data/local/aospacademy-wg` and runs the `wireguard` mode, then deletes the directory, whether or not those worked. No marker: it runs whenever the directory is there.
1. **HOME role.** `cmd role add-role-holder android.app.role.HOME org.fossify.home 0`: Fossify Launcher is the home screen without a chooser. A launcher chosen later in Settings is kept. Marker: `home-role`.
2. **Development settings.** The same values `aosp-academy device settings` applies on the stock system: `development_settings_enabled` 1 (Developer options shown), `stay_on_while_plugged_in` 15 (Stay awake while charging), `window_animation_scale`, `transition_animation_scale` and `animator_duration_scale` 0 (UI tests expect it, and screens settle at once), `verifier_verify_adb_installs` 0 (no verification scan of adb installs), and `adb_allowed_connection_time` 0 (an authorised PC's key never expires), and the system settings `screen_brightness_mode` 0 and `screen_brightness` 64 (manual, about 25 %, since Stay awake keeps the OLED panel on). Each is read back after it is set. SettingsProvider has resource defaults for only some of the nine in this tag, so all nine are set here, in one place. Marker: `dev-settings`.
3. **Hidden icons.** Two AOSP launcher entries are disabled with `pm disable`, because their apps stay for what they do in the background and a Fossify app is the one to open: **Files** (`com.android.documentsui/.LauncherActivity`; DocumentsUI's picker stays) and **Keyboard** (`com.android.inputmethod.latin/.setup.SetupActivity`; LatinIME stays as the fallback, and its settings remain under Settings, System, Keyboard). Neither entry is gated on a resource in this tag, so an overlay can't do it. `pm enable` on the same component brings an icon back. Markers: `files-icon`, `keyboard-icon`.
4. **Teal icons.** Every `org.fossify.*` app gets the teal launcher icon, to match the wallpaper. Inside the apps Fossify already follows the system's Material You colours; the icon colour is a separate per-app choice, stored as one enabled activity alias (`SplashActivity.Teal`, with `.Green` disabled) plus two preferences the app reconciles on every start (`app_icon_color` and `last_icon_color` in `shared_prefs/Prefs.xml`). The service sets all three, as the app's own Customize screen does. Markers: `<package>.icon`.
   Then **Fossify Clock lets the screen turn off**: its setting "Prevent phone from sleeping while the app is in the foreground" (`prevent_phone_from_sleeping` in the same `Prefs.xml`) is on by default, and a clock left open held the screen on for seven hours. The service turns it off once, so turning it back on in the app's settings sticks. Marker: `clock-sleep`.

5. **Bluetooth off.** Android turns Bluetooth on at boot by default; the service switches it off (`cmd bluetooth_manager disable`) together with Bluetooth scanning (`ble_scan_always_enabled` 0, which otherwise lets apps scan while Bluetooth is off). Android keeps the adapter's last state across reboots, so this is done once: switching Bluetooth on later in Settings or Quick Settings sticks. Marker: `bluetooth-off`.

If anything changed in steps 3 and 4, it force-stops the HOME role holder so the icons refresh.

It reports where the log buffers can't lose it, because the first boot's log lines can roll out of logcat within minutes:

| File in `/data/local/aospacademy-firstboot/` | Content |
| --- | --- |
| `status` | `running` while it works, then `done failures=<n>`. |
| `log` | Every line it logs, with a date and time. The same lines go to logcat under the tag `aospacademy-firstboot`. |
| `charge-limit` | The charge-limit result (below). |

`aosp-academy deploy` reads all three as root (`su 0 cat ...`).

## The log size rule

logd's default buffer is 256 KiB per log, which this phone's vendor log noise (see the [backlog](backlog.md#vendor-noise)) rolls over within minutes. The image makes every buffer **16 MiB** on every boot.

A property can't do it: logd in this tag reads `ro.logd.size` and `persist.logd.size` at start only on automotive and desktop hardware types (`system/logging/logd/LogSize.cpp`). So `init.aospacademy.rc` has a service, `aospacademy_logsize`, that runs `logcat -b main,system,crash,events,radio,kernel -G 16M` as root, started when logd sets `logd.ready=true`. logd clears that property when it restarts, so the rule also re-applies the size after a logd restart. `adb logcat -g` shows the size.

## The charge limit

The phone lives on its charger, so the image caps the charge at **80 %**, as the stock system does with Motorola's Battery protection on.

**How stock does it.** Moto Actions passes the limit through a Motorola service in `system_server` to the vendor health HAL (`motorola.hardware.health-service`), which writes it to a parameter of the vendor kernel module `qpnp_adaptive_charge`: `upper_limit` 80, with `lower_limit` -1, meaning auto mode. Stock's `dumpsys battery` shows `AdaptiveCharging ... mUpperLimit:80, mLowerLimit:-1`. The image has the module and the HAL, but not Motorola's client.

**How the image does it.** `init.aospacademy.rc` starts the service `aospacademy_chargelimit` (the first-boot script with the argument `charge-limit`) after boot and whenever **`persist.aospacademy.charge_limit`** changes. The default is 80 from the product `build.prop`; values from 50 to 100 are accepted, and anything else is logged and left unchanged. The service:

1. removes the previous result file (it lives in `/data` and outlasts reboots, so a deploy must not read the last boot's result as this one's);
2. writes the value to `/sys/module/qpnp_adaptive_charge/parameters/upper_limit`, the same single write the HAL makes on stock;
3. waits 30 s, because the module re-evaluates on its next battery update;
4. reads the property again, and applies it in turn if it changed during the wait (init's `start` does nothing for a oneshot service that is still running, so a second `setprop` within 30 s would otherwise be lost);
5. records `upper_limit=<n>, blocking=<0|1> (1 = holding charge off)` in `charge-limit` and the log.

To set another limit: `adb shell su 0 setprop persist.aospacademy.charge_limit 85`. The value is stored in `/data` and wins over the default until the next deploy.

**How the module decides.** From Motorola's source for the module (`drivers/power/qpnp_adaptive_charge/qpnp_adaptive_charge.c` in [motorola-kernel-modules](https://github.com/MotorolaMobilityLLC/motorola-kernel-modules)), confirmed on the device. It re-checks the level whenever the battery reports a change and whenever the limit is written. With L the limit:

| Battery level | What the module does |
| --- | --- |
| above L+1 | Suspends charging and holds the charge current at 0; the phone runs from the battery (status "Not charging"). |
| exactly L+1 | Lets the charger power the phone, but still holds the battery current at 0. |
| exactly L | Changes nothing: this is the hysteresis. |
| below L | Charges. |

So the level settles between L-1 and L+2, and with the limit at 80 the phone sits at about 84 to 86 % after charging past it.

**100 means charge to full,** with one edge. If charging is already held off and the level is exactly 100 %, it stays held off until the level falls to 99, because at the limit the module keeps its state. From any lower level, 100 resumes charging at once: tested at 84 %, the status was "Charging" within 5 s and `blocking` went from 1 to 0, and back to 1 within seconds of setting 80 again. The module's own off value, `upper_limit` -1, would clear a hold even at 100 %, but the service accepts only 50 to 100 and never writes it: the [decision](../reference/decisions.md#charge-limit-80-and-no-1-write) is to keep the limit at 80 and make no new kind of write.

!!! danger "Never read the limits back, and never bulk-read module parameters"
    The service **writes** `upper_limit` and never reads it or `lower_limit` back. It checks the result through **`blocking`** only, a read-only parameter with its own getter that reads 1 while the module holds charging off. Do the same by hand.

    **Never read `/sys/module/*/parameters/*` in bulk on this phone.** Reading sysfs runs driver code, and one of the vendor charger modules has a broken int parameter. Reading the parameters of the charger-related modules (`bq25980_mmi`, `mt6375_battery`, `mtk_charger_*`, `qpnp_adaptive_charge` and others) in a loop hits a NULL dereference in `param_get_int` and panics the kernel (boot reason `kernel_panic,null`). The bug is in the stock kernel too, so it isn't the image's doing; the phone reboots on its own. Read one named node at a time, only one you already know is safe, and look for nodes in static sources first (the vendor's init `.rc` files, `strings` on its binaries).

## The patches

`image/patches/` holds unified diffs against upstream AOSP projects, one project per file, applied by `apply-local.sh` ([Build the image](building.md#patches) explains the mechanics and the naming). There are four:

| Patch | Project | Why |
| --- | --- | --- |
| `build-soong-0001-build-prop-visibility-for-device-aospacademy.patch` | `build/soong` | Adds `//device/aospacademy/gsi` to the visibility lists of the `system_ext-build.prop` and `product-build.prop` modules, which upstream makes visible only to the GSI's own directory. The [Android.bp mirror](#the-androidbp-mirror) builds those `build.prop` files the same way the GSI does, so it needs them. |
| `build-blueprint-0001-soong-heap-limit-80-percent-of-ram.patch` | `build/blueprint` | Sets the Go runtime's soft memory limit (`debug.SetMemoryLimit`) for `soong_build` to 80 % of the machine's RAM, read from `/proc/meminfo`, so its garbage collector runs before the heap leaves RAM. Without it, Android 17's analysis swaps for more than 50 minutes without finishing on a 32 GB builder. It is the only patch that changes the build system rather than the image. [Build the image](building.md#memory) has the measurements. |
| `frameworks-base-0001-vibrator-no-unknown-amplitude-to-hal.patch` | `frameworks/base` | Stops `Error setting amplitude to -1.0` failures. The framework records amplitude -1, meaning "unknown", when the vibrator turns on, and `SetAmplitudeVibratorStep.turnVibratorBackOn` can pass that value back to `setAmplitude`. This phone's HAL (`android.hardware.vibrator-service.mediatek`, capability `AMPLITUDE_CONTROL` only) rejects -1 with `IllegalArgumentException`. The patch makes `VintfHalVibrator.setAmplitude` skip negative values, so the vibrator keeps its current strength. Android 17 still has the bug: Google's Android 17 GSI logs these errors on this phone. |
| `packages-apps-Launcher3-0001-home-priority-below-image-launcher.patch` | `packages/apps/Launcher3` | Gives Quickstep's HOME filter priority -1, below Fossify Launcher's 0, so first boot never shows a "Select a home app" chooser. On first boot the setup stub (`com.android.provision`) holds the HOME role, then leaves it; the role controller then picks a fallback holder, the highest-priority HOME activity, and picks none when the top two tie. With both at 0 the HOME intent fell through to the chooser about 8 s before the first-boot service could assign the role. Quickstep stays installed (SystemUI binds its quickstep service for gestures and recents) and can still be chosen as home. |

`gpuservice` needs no patch: the Motorola kernel doesn't carry the GPU-work BPF program (the `gpu_work_period` tracepoint), and `android-17.0.0_r1`'s `GpuWork::getBpfMap` uses `map.init()`, which fails without aborting, so `gpuservice` stays up and logs one `GpuWork: Failed to attach bpf program` warning.
