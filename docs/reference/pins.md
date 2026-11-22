# Pins (`toolchain.json`)

`toolchain.json`, at the repository root, is the single source of truth for every version this project uses: the workstation's tools, the device procedure's inputs, the image's apps, the Google GSI and the AOSP release. `aosp-academy setup` reads it on the workstation, `aosp-academy image` on the build node, and `aosp-academy check` re-verifies it. Nothing else in the repository names a version.

A **pin** is a download recorded with its exact URL and its hash, the fingerprint of the file's bytes. A pinned file is downloaded only from that URL, kept only if its hash matches, and never silently replaced. This matters more here than in most projects: the device procedure was validated with specific versions, and a newer Magisk or `adb` might behave differently in ways nobody has tested on this model. Pinning means your environment matches the one the procedure was proven on, and anyone can reproduce it exactly.

## The sections

Keys that start with `_` (`_comment`, `_note`) are explanations for people; the code ignores them. Read them: they record why a pin is what it is.

### `winget`

The system tools that `setup` installs through winget on Windows: Microsoft OpenJDK 21, Git, GitHub CLI, scrcpy, jadx (its GUI), 7-Zip, and Android Studio, which is marked `optional` and installed only with `--studio`. winget packages carry no version or hash here: winget installs the current release and checks the installer against the hash in its own package manifest. A package that is already installed is left as it is. On Linux and macOS, `setup` only lists the missing ones (`openjdk-21-jdk`, `git`, `gh`, `scrcpy`) for your package manager.

### `androidSdk`

- **`cmdlineTools`**: Google's SDK command-line tools (version 23.0), with one URL and **SHA-1** per host OS (`windows`, `linux`, `mac-x64`, `mac-arm64`). SHA-1 because that is the checksum Google itself publishes for SDK packages, in its `repository2-3.xml`; it is the publisher's own value, not one computed here.
- **`packages`**: the SDK packages `setup` installs with the SDK's `android` CLI, by path: `platform-tools`, `platforms/android-37.0` (Android 17, API 37, the image's OS), `build-tools/37.0.0`, `ndk/30.0.16248370`. The SDK manager verifies these itself. The commands use these exact `build-tools` and NDK directories, not whatever is newest, because Android Studio installs its own versions into the same SDK and the newest would silently win.

The SDK's `platform-tools` is the one Android Studio uses. Device work uses the pinned copy in `work/platform-tools` (`inputs.platformTools`, below), and `check` fails if the two report different versions.

### `jars` and `archives`

Single files downloaded into `work/tools/`, each with a SHA-256 or SHA-1:

| Pin | Used for |
| --- | --- |
| `r8-9.5.33.jar` | D8, which builds the stock helpers (`stock build`, `aosp-academy d8`) |
| `apktool_3.0.3.jar` | decoding and rebuilding APK resources (`aosp-academy apktool`) |
| `jadx-1.5.7.zip` (an archive, unpacked to `work/tools/jadx`) | the jadx command-line decompiler; the winget package is the GUI only |
| `gradle-9.9.2-bin.zip` (an archive, unpacked to `work/tools/gradle`) | Gradle for `new-app`, which writes each new project's wrapper with it |

An unpacked archive gets a `.pinned-sha256` stamp, so `setup` re-extracts it when the pin changes and `check` can confirm what's there came from the pinned file.

### `appTemplate`

The versions a project from `aosp-academy new-app` starts with: Gradle and its distribution SHA-256, the Android Gradle Plugin, compileSdk, targetSdk and minSdk, the build-tools, and the AndroidX test libraries of the template's instrumented test. A new project copies them into its own build files and wrapper, so changing them affects only projects created afterwards. Gradle here and in `archives` are the same version and checksum.

### `deviceTools`

Optional tools for the prepared device, and the image's own inputs. Bumping these is routine, unlike `inputs`.

- **`downloads`**: files for `work/device-tools/`.
    - `frida-server` for arm64 (`extract` names the file unpacked from the `.xz`), the agent that runs as root on the phone.
    - The F-Droid client APK, for the stock system (install it by hand with `adb install`).
    - The **16 Fossify apps** built into the image. They are marked **`buildOnly`**: only the build node downloads them (`aosp-academy image inputs`), and `setup` skips them.
- **`frida`**: `version` must equal frida-server's version above, and `toolsVersion` is the `frida-tools` release; `setup` pip-installs both into `work/.venv-frida`. The PC tools and the server must match.
- **`gsi`**: Google's AOSP arm64 GSI for Android 17, build `CP2A.260605.012`, used by `aosp-academy gsi download`. It is not fetched by `setup`: it is about 1 GB and behind Google's terms, which you accept explicitly.
- **`wireguardTools`**: the source of the image's `wg`: `repo`, `tag` and `commit` (wireguard-tools, GPL-2.0-only). `image inputs` clones the tag and refuses it if the commit differs, so a moved tag is caught.
- **`aosp`**: what the build node builds. `manifest` is AOSP's manifest repository, `tag` the release (**`android-17.0.0_r1`**, build `CP2A.260605.016`, the source release of the same Android 17 drop as the pinned GSI binary, so what you build matches what was validated), `lunch` the build target (`aospacademy_arm64-trunk_staging-userdebug`) and `treeDir` the default `AOSP_DIR` (`~/aosp17`).

### `inputs`

**The device procedure's exact tested inputs**, downloaded into `work/`. These are what the [walkthrough](../device/walkthrough.md) was carried out with, on two units:

| Pin | Used in |
| --- | --- |
| `platformTools` | every `adb` and `fastboot` command (`work/platform-tools`); per host OS, with Google's SHA-1 |
| `apks`: DFRoot 4.7, KernelSU 3.3.1, Magisk 31.1 | temporary root, then persistent root |
| `testDpcQr` | Google's Test DPC QR image, for provisioning a Wi-Fi-only phone at first setup |
| `valProtocol` | the bootloader (LK) patching tool, pinned to a **git commit**, cloned into `work/val-protocol` |
| `motorolaDriver` | the Windows USB driver: no stable URL, so it is downloaded by hand; `setup` and `check` compare it with the tested driver's SHA-256 |

**Change these only when you deliberately re-validate the procedure**, and record the result on the [validation page](../environment/validation.md). A newer Magisk or `adb` might be fine, but nobody has tested it on this model, and the stages it is used in can leave a phone unbootable.

## Signer pins

The F-Droid and Fossify APKs carry a second pin, **`signerSha256`**: the SHA-256 of the certificate the APK is signed with. The file hash fixes the bytes; the signer fixes the **publisher**. When a pin is moved to a newer version, `check` runs `apksigner verify --print-certs` on the new file and fails unless the certificate matches, so a re-pin can't silently accept a build signed by someone else.

| APK | Signer published by |
| --- | --- |
| F-Droid | [F-Droid's signing keys page](https://f-droid.org/docs/Release_Channels_and_Signing_Keys/) |
| Fossify apps (one certificate for all 16) | Fossify; hash and signer taken from F-Droid's signed index (`index-v2`) when pinned |

`check` verifies the signers of the APKs on the workstation. The build node's `image inputs` checks only the SHA-256, which already fixes every byte of an APK whose signer was checked when it was pinned.

## Changing a pin

1. Take the new URL and hash **from the publisher**: a release page's checksum, F-Droid's signed index, Google's `repository2-3.xml` for SDK packages. Never compute a hash from a file you downloaded yourself and pin that: the point is to check the download against the publisher.
2. Edit `toolchain.json`. Keep the `_note` up to date, including what the pin was before and why it moved.
3. Delete the old file in `work/` if it has the same name as the new one. A file that is present but doesn't match its pin is never overwritten: `setup` stops and asks you to look at it.
4. Re-run `aosp-academy setup` (on the build node, `aosp-academy image inputs` for a `buildOnly` pin), then `aosp-academy check`.
5. Commit the pin change on its own branch, with the reason in the message. A change to an image input (`buildOnly`, `aosp`, `gsi`) goes through the [change loop](../environment/index.md): build, deploy, verify, then merge.

Moving `deviceTools.aosp.tag` is a project of its own: [move to a new AOSP release](../environment/tag-moves.md).

## Platform-tools and the flashing stages

`inputs.platformTools` is **37.0.3**, the version the Android SDK installs, so that Android Studio's `adb` server and the project's are the same version and don't fight over the phone. The bootloader and Magisk stages were carried out on both units with platform-tools **37.0.1**, and haven't been run with 37.0.3: they run once per unit. The 37.0.1 version and its Windows SHA-1 are recorded in the pin's `_note`.

To move platform-tools again, besides the steps above: stop any running ADB server (`adb kill-server`) and delete `work/platform-tools/` and `work/platform-tools.zip`. `setup` refuses to unpack over a folder that holds another version.
