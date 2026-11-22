# Validation

A new image is merged only once it has been put on the phone and checked. This page is the checklist it must pass, and the image that passed it last. The phone it applies to is the one in [Hardware](../device/hardware.md): a Moto G Power 2026, XT2617V, with its stock Android 13 vendor layer, Wi-Fi and no SIM. Nothing here says anything about another model or firmware; read the [disclaimer](../reference/disclaimer.md).

## The checklist

Most of it runs by itself: `./aosp-academy deploy` ends with the report and `device test` ([Deploy and verify](deploying.md)). The rest is a few commands on the phone. Run the whole list for a tag move or a change that touches the vendor boundary; for a smaller change, the automatic part plus the change's own check, named in the build request.

### Automatic (the deploy)

| Check | Pass |
| --- | --- |
| Fetch | Every part and the joined image match the build node's SHA-256; `build.prop` fetched. |
| Install | The DSU installer reaches `READY`. |
| Boot | The phone comes up in the image: `ro.product.name` is `aospacademy_arm64`, and `gsi status` says `running`. |
| Authorisation | With keys built in, no Allow tap; the report's `AdbKeys` row is `built in (N keys)`. |
| Report | Every row as in [the report table](deploying.md#the-report): first boot `done failures=0` with 16 icons, HOME `org.fossify.home`, animations `0/0/0`, 16 MiB log buffers, `America/New_York`, Files and keyboard icons hidden, charge limit `upper_limit=80` applied, network validated with probes to `connectivitycheck.grapheneos.network` and NTP from `pool.ntp.org`, crash log empty. |
| `device test` | 15 of 15 (device, root, logs, native, app, debug including `adb root`, JDWP, trace, Frida, mirror). |

### By hand, on the image

Run these from a shell on the device node with the pinned `adb` (`./aosp-academy shell`). `su 0` is the image's root.

| Check | How | Pass |
| --- | --- | --- |
| SELinux | `adb shell getenforce`; `adb logcat -d \| grep avc:` | `Enforcing`; denials are vendor noise only (`batt_health` reading `default_prop`, `statsbootstrap` lookups, `vendor_init`). |
| Crashes | `adb logcat -d -b crash`; `adb shell su 0 ls /data/tombstones /data/anr` | Empty. Watch for the SystemUI crash in the [backlog](backlog.md). |
| `gpuservice` | `adb logcat -d \| grep -i gpuwork` | No abort; at most one `GpuWork: Failed to attach bpf program` warning. |
| Vibrator | Trigger a vibration (a key press with haptics, a notification); `adb logcat -d \| grep "setting amplitude"` | No `Error setting amplitude to -1.0`. |
| Google endpoints | `adb logcat -d -b all \| grep -E "gstatic\|www.google.com\|time.android.com"` | No lines. |
| adb authorisation | `adb shell getprop ro.adb.secure`; `adb shell su 0 ls /data/misc/adb` | `1`; with keys built in, `/data/misc/adb` holds no `adb_keys`, so the built-in list did the trusting. |
| No home chooser | `adb logcat -d -b events \| grep ResolverActivity` after the first boot | No lines: the HOME role went straight to Fossify Launcher. |
| JDWP | `adb jdwp` | Lists `system_server`, SystemUI and the running apps; the count follows how many apps are running. |
| Charge limit | On the charger above the limit: `adb shell su 0 cat /sys/module/qpnp_adaptive_charge/parameters/blocking`; `adb shell dumpsys battery` | `blocking` 1 and "Not charging" while the level is above 81 % with the limit at 80 (the phone sits at about 84 to 86 % after charging past it). Read `blocking` only, never `upper_limit` or `lower_limit`, and never list the parameters directory ([why](image.md#the-charge-limit)). |
| Persistence | `adb reboot`; then `./aosp-academy gsi stock` and `./aosp-academy gsi boot` | Back in the image after each, with its data and first-boot state intact (about 45 s for a reboot, 55 s for a switch). |
| DocumentsUI | Open a file from any Fossify app | The system picker opens (OPEN_DOCUMENT, GET_CONTENT and CREATE_DOCUMENT resolve to DocumentsUI). |

### Hardware (tag moves and vendor-boundary changes)

Compare with the [current image](#current-image) and with step 0 of the [tag move](tag-moves.md). `./aosp-academy device info --label <name>` captures an inventory to compare.

| Area | Current result |
| --- | --- |
| Display | 4 modes, 120/90/60/30 Hz (`dumpsys SurfaceFlinger` `displayModes`) |
| Wi-Fi | Validated in about 6 s (5 GHz) |
| Bluetooth, NFC | Both work; NFC on, Bluetooth off by default (first boot switches it off; turn it on to test it) |
| GNSS | MediaTek MNLD HAL (`@2.0`) |
| Cameras | 2 of 3 exposed (a limit of the GSI's camera interface) |
| Sensors | 41 hardware sensors (`dumpsys sensorservice`), including the Motorola gestures |
| Fingerprint | HIDL `@2.1` HAL registered, with the Motorola `IMotoFingerPrint` HALs, and `feature:android.hardware.fingerprint` present (enrolment not yet tested: [backlog](backlog.md)) |
| Audio | Speaker output |
| Modem | Up; cellular untested (no SIM) |
| HALs | `lshal` lists 156 entries; `hwservicemanager` logs "Cannot find" lookups for 16 HIDL interfaces (keymaster, weaver, OMX, DRM, secure element and others: clients probing HIDL before AIDL), with nothing failing to start |
| Charge module | `/sys/module/qpnp_adaptive_charge/parameters` exists (don't read it) |

When an image passes, the [Current image](#current-image) section below is replaced with it, then the change is merged.

## Current image

<!-- current-image: filled in by the machine that deploys -->
**Build 26**, from branch `home-default` at `d6e6f38`, built Sun Nov 22 11:40:24 EST 2026 (`ro.build.date`), SHA-256 `4b505759…1aef`, validated 2026-11-22: build 25 plus the Launcher3 patch (Quickstep's HOME priority -1), so Fossify Launcher is the HOME role's fallback holder and first boot shows no home chooser.

The image on the phone is the product **`aospacademy_arm64`**, Android 17 (`android-17.0.0_r1`, `CP2A.260605.016`), installed with `./aosp-academy deploy` alone, with no tap on the phone. The git tag `baseline-4` marks build 25 before it, and `baseline-3` build 24. Each `baseline-N` tag marks a validated image's commit; `git tag -n1 'baseline-*'` lists them with their image's SHA-256.

- **No home chooser:** the setup stub left the HOME role at first boot and the role controller gave it to `org.fossify.home` as the fallback holder 4 ms later; no `ResolverActivity` in the events log, and none seen on the screen. The first-boot service's own assignment found the role already held. On build 25 the same moment gave no holder, and the chooser opened 8 s before the first-boot service set the role.
- **Report:** all green, as for build 25, with the charge limit holding (`blocking=1` at 80 %, on AC, "not charging"; battery health good, 30 C).
- **`device test`:** 15 of 15.
- **Wired bypass, reboots, by hand:** not repeated; the image change is one manifest priority. Build 25 passed the wired bypass, build 23 the reboot round trip, build 21 the by-hand checklist.
- **Hardware:** as in the table above.

## Tools and platform checks

| Item | Result |
| --- | --- |
| Android Virtualization Framework | Absent on this phone: no `ro.boot.hypervisor.*`, no `/dev/kvm`, no `com.android.virt` APEX on stock, no Terminal app. Hence the AVF packages left out of the image. |
| Frida 17.27.4 | `device frida start` pushes and starts the server; `frida-ps -Ua` lists the running apps. |
| Perfetto | `device trace` records and pulls traces. The config file must live in `/data/misc/perfetto-configs/`; `/data/local/tmp` is refused by SELinux. |
| simpleperf | Unusable on this phone: no perf events (`cpu-cycles` and `cpu-clock` both "not supported on the device"). |
| SDK `adb` and pinned `adb` | The same version, so Android Studio and the project's shell share one adb server; `aosp-academy check` enforces equality. |
