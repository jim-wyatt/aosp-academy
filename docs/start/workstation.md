# Set up a workstation

The workstation is the PC you work at and plug the phone into: the **device node**. One command installs everything it needs, and a second proves that it works. Both are safe to run more than once: each step checks whether its work is already done and skips it.

The commands work the same on Windows, Linux and macOS. They are written here as `aosp-academy <command>`; from the repository folder that is `.\aosp-academy <command>` in a Windows terminal (it runs `aosp-academy.cmd`) and `./aosp-academy <command>` on Linux and macOS.

## 1. Two prerequisites: Python and git

The tooling is one Python program that uses only Python's standard library, so it needs nothing installed with `pip`. It needs **Python 3.11 or newer** and **git**.

=== "Windows"

    ```text
    winget install Python.Python.3.12 Git.Git
    ```

    Open a **new** terminal afterwards, so the updated PATH is picked up. If typing `python` opens the Microsoft Store, the Store's placeholder is still first on PATH; see [troubleshooting](../reference/troubleshooting.md#environment).

=== "Linux"

    Use your distribution's packages, for example on Debian or Ubuntu:

    ```bash
    sudo apt install python3 git
    ```

=== "macOS"

    Python 3.11+ from [python.org](https://www.python.org/downloads/) or Homebrew (`brew install python git`).

The launchers run Python in isolated mode (`-I`), so a stray module in the current folder or in `PYTHONPATH` can't shadow the standard library or the package, and they refuse to start on a Python older than 3.11.

## 2. Get the repository

Clone it to a folder on a **local drive**: not a network share and not a WSL path seen from Windows (`\\wsl$\...`). Python's virtual environments break on those, and `setup` refuses to run from a network path.

```bash
git clone https://github.com/jim-wyatt/aosp-academy.git
cd aosp-academy
```

## 3. Windows only: the Motorola USB driver

This is the one download the setup can't do for you, because Motorola's site has no stable direct link. Go to [Motorola's USB driver page](https://en-us.support.motorola.com/app/usb-drivers), download the **64-bit Windows** installer, save it as `work\Motorola_Mobile_Drivers_64bit.msi` in the repository (create the `work` folder if it doesn't exist), and install it.

`setup` compares the file with the SHA-256 of the driver the procedure was tested with (`inputs.motorolaDriver` in `toolchain.json`) and says whether it matches. If it doesn't, you probably have a newer driver: check in the file's properties that it is signed by Motorola Mobility before you install it.

!!! info "Why a driver at all?"
    Windows can talk ADB to the phone without it, but **Fastboot** (the bootloader mode the walkthrough uses to unlock) needs Motorola's driver. Without it you get "error 28" in Device Manager and an empty device list at the worst possible moment. Linux and macOS need no driver.

## 4. Run the setup

In the repository folder, as yourself (not as administrator: the installers ask for elevation when they need it):

```text
aosp-academy setup --studio --accept-sdk-licenses
```

| Option | What it does |
| --- | --- |
| `--studio` | Also installs Android Studio (Windows, through winget; about 1.5 GB). Leave it off if you only want the command-line tools; you can add it later. On Linux and macOS, install Studio from [developer.android.com](https://developer.android.com/studio) yourself. |
| `--accept-sdk-licenses` | Accepts [Google's Android SDK terms](https://developer.android.com/studio/terms) for you. Read them first. Without the flag, setup shows them and asks, which needs an interactive terminal. |
| `--skip-system` | Leaves out the system packages (winget on Windows, the package check on Linux and macOS). |
| `--skip-sdk` | Leaves out the Android SDK step. |
| `--skip-inputs` | Leaves out the device procedure's inputs and the device tools (steps 4 and 5 below). |

On Windows, expect a few User Account Control prompts as winget installs the JDK and the other system tools. The whole run takes 10 to 30 minutes depending on your connection; the NDK is the slow download.

### What it installs, and where

Every download is pinned in `toolchain.json` with its hash and verified before it is used ([pins](../reference/pins.md) explains the file). A file that is already present but doesn't match its pin is never overwritten: setup stops and tells you, because someone has to look at it.

| Step | What | Where |
| --- | --- | --- |
| 1. System tools | Windows: winget installs Microsoft OpenJDK 21, Git, GitHub CLI, scrcpy, jadx (the GUI), 7-Zip, and Android Studio with `--studio`. Linux and macOS: setup lists whatever of `openjdk-21-jdk`, `git`, `gh` and `scrcpy` is missing, for your package manager. | system-wide |
| 2. JDK and SDK | Finds JDK 21 and sets `JAVA_HOME`. Downloads Google's command-line tools for your OS and installs the pinned SDK packages: platform-tools, the Android 17 platform (`platforms/android-37.0`, API 37), `build-tools/37.0.0` and NDK `30.0.16248370`. | `ANDROID_HOME`: `%LOCALAPPDATA%\Android\Sdk` on Windows, `~/Android/Sdk` elsewhere (an existing `ANDROID_HOME` is kept) |
| 3. JARs and archives | R8 9.5.33 (its D8 builds the stock helpers), apktool 3.0.3, the jadx 1.5.7 command line | `work/tools/` |
| 4. Device procedure inputs | The pinned platform-tools **37.0.3** (`adb`, `fastboot`), the DFRoot, KernelSU and Magisk APKs, Google's Test DPC QR image, Val Protocol at its pinned commit; the Motorola driver is checked, not downloaded | `work/` |
| 5. Device tools | frida-server for the phone (unpacked), the F-Droid APK for the stock system. The image's own inputs, the Fossify APKs, are left to the build node (`aosp-academy image inputs`). | `work/device-tools/` |
| 6. Python environments | `.venv` (Val Protocol's requirements), `.venv-frida` (`frida` and `frida-tools`, the same version as the server), `.venv-docs` (Zensical, for this site) | `work/` |
| 7. Git | `core.hooksPath = .githooks`: the pre-commit hook that keeps device data out of the repository ([git workflow](../reference/git-workflow.md)) | the repository's git config |

On Windows, `JAVA_HOME` and `ANDROID_HOME` are saved as user environment variables, so new terminals and Android Studio see them; terminals that were already open don't until you reopen them. On Linux and macOS setup doesn't edit your shell profile: `aosp-academy shell` and `aosp-academy env` (below) give a shell the right variables.

The three Python environments are separate on purpose: Val Protocol, the bootloader tool, stays minimal; Frida's PC tools must match the server on the phone; and the docs tools have their own dependencies. A virtual environment records the absolute path it was created at, so if you move the repository folder, setup notices and recreates each one.

Nothing in this step talks to a phone.

## 5. Prove it works

```text
aosp-academy check
```

`check` doesn't stop at version numbers: it uses each tool. It confirms JDK 21 and the SDK packages, runs D8 and aapt2, checks every pinned JAR, checks that the SDK's `adb` is the same version as the pinned one, rebuilds the stock helpers and modules and compares them with the committed copies, checks the module scripts inside the ZIPs (LF line endings, no byte-order mark, executable), runs the unit tests, decompiles a helper with jadx, cross-compiles a C program for the phone's CPU with the NDK, compiles Java against the pinned platform, builds this site, checks every shell script with `bash -n` (Git Bash on Windows), re-verifies every pinned input and the signing certificates of the pinned APKs, and checks the git safety settings: the hook is active, private paths are ignored, and the commit email is a GitHub no-reply address.

It prints one line per check and ends with a count such as `... checks: ... passed, 0 failed, ... skipped or warned`. The exit code is the number of failures. A missing Android Studio is only a warning. It never talks to the phone and never starts an ADB server. If something fails, [troubleshooting](../reference/troubleshooting.md) covers the common causes.

## 6. A shell with the tools on PATH

```text
aosp-academy shell
```

opens a new shell in the repository folder (PowerShell 7 or `cmd` on Windows, your `$SHELL` elsewhere) with the pinned tools first on PATH. `exit` leaves it. Inside it:

| On PATH | From |
| --- | --- |
| `adb`, `fastboot` | `work/platform-tools`, the pinned 37.0.3, **first**, so a bare `adb` is always the tested version |
| `java`, `javac` | the JDK in `JAVA_HOME` |
| `android`, `sdkmanager` | the SDK's `cmdline-tools/latest` |
| `d8`, `aapt2`, `apksigner`, ... | the pinned `build-tools/37.0.0` |
| `ndk-build` and the NDK's top-level tools | the pinned NDK |
| `jadx` | `work/tools/jadx` |
| `python` | `work/.venv`, the Val Protocol environment the walkthrough uses |
| `frida`, `frida-ps`, `frida-trace` | `work/.venv-frida` |
| `7z` | 7-Zip (Windows) |

It also sets `ANDROID_HOME`, `JAVA_HOME`, `ANDROID_NDK_HOME`, and `ADB` (the pinned `adb`, which scrcpy honours). Every command in these docs assumes this shell.

If you'd rather keep your own shell, `aosp-academy env` prints the same settings as statements for it:

=== "PowerShell"

    ```powershell
    .\aosp-academy env | Invoke-Expression
    ```

=== "bash / zsh"

    ```bash
    eval "$(./aosp-academy env --shell bash)"
    ```

=== "cmd"

    ```text
    aosp-academy env --shell cmd > %TEMP%\aa-env.cmd && call %TEMP%\aa-env.cmd
    ```

`--shell` takes `pwsh`, `cmd` or `bash`; without it, the default is PowerShell 7 (or `cmd`) on Windows and bash elsewhere.

## VS Code

Open the repository folder in VS Code and accept the recommended extensions. `.vscode/settings.json` makes **aosp-academy shell** the default terminal profile on Windows, so a new terminal (++ctrl+shift+grave++) is already the shell above. `.vscode/tasks.json` has tasks for the common commands: *Set up the workstation*, *Check the workstation*, *Rebuild stock artifacts and compare* (the default build task, ++ctrl+shift+b++), *Test the phone*, *Deploy the newest image* and *Mirror the phone (scrcpy)*.

## Android Studio and the phone

Android Studio uses the SDK's `adb`; every `aosp-academy` command uses the pinned copy in `work/platform-tools`. The two are the same version (37.0.3), so Studio's ADB server and ours don't fight over the phone, and `check` fails if they ever drift apart. If Studio offers a platform-tools update, decline it, or move the pin deliberately ([pins](../reference/pins.md)).

During the low-level stages of the [walkthrough](../device/walkthrough.md) (backups, flashing, unlocking), keep Studio closed all the same: nothing else should be talking to the phone while those run.

Next: [set up the build node](build-node.md), or go straight to [your first session](first-session.md).
