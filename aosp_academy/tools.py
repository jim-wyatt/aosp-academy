"""Where the workstation's tools are: the pinned SDK packages, JDK, NDK, JARs, venvs.

The pinned build-tools and NDK (toolchain.json), not whatever is newest: Android Studio installs
its own versions into the same SDK, and the newest would silently win.
"""
from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

from .core import EXE, WINDOWS, WORK, pins, warn

TOOLS = WORK / "tools"
CACHE = WORK / "cache"
BAT = ".bat" if WINDOWS else ""
VENV_BIN = "Scripts" if WINDOWS else "bin"


def sdk() -> Path | None:
    v = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if not v and WINDOWS:
        v = _user_env("ANDROID_HOME")
    if not v:
        default = Path(os.environ.get("LOCALAPPDATA", "")) / "Android" / "Sdk" if WINDOWS else Path.home() / "Android" / "Sdk"
        return default if default.exists() else None
    return Path(v)


def java_home() -> Path | None:
    v = os.environ.get("JAVA_HOME") or (_user_env("JAVA_HOME") if WINDOWS else None)
    if v and (Path(v) / "bin" / f"javac{EXE}").exists():
        return Path(v)
    j = shutil.which("javac")
    return Path(j).resolve().parent.parent if j else None


def _user_env(name: str) -> str | None:
    """A persistent per-user environment variable (Windows registry), for shells opened before setup set it."""
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as k:
            return winreg.QueryValueEx(k, name)[0]
    except OSError:
        return None


def _pinned(kind: str) -> str | None:
    for p in pins()["androidSdk"]["packages"]:
        if p.startswith(kind + "/"):
            return p.split("/", 1)[1]
    return None


def pinned_dir(kind: str, quiet: bool = False) -> Path | None:
    """The pinned build-tools or ndk directory; the newest present (with a warning) if it's missing."""
    s = sdk()
    if not s:
        return None
    base, pin = s / kind, _pinned(kind)
    if pin and (base / pin).is_dir():
        return base / pin
    present = sorted((d for d in base.glob("*") if d.is_dir()), key=lambda d: [int(x) if x.isdigit() else 0 for x in d.name.split(".")])
    if present and not quiet:
        warn(f"{kind} {pin} (pinned) is not installed; using {present[-1].name}. Run: aosp-academy setup")
    return present[-1] if present else None


def platform_api(name: str) -> int:
    """The API level of a platform directory name: android-36 -> 36, android-37.0 -> 37."""
    return int(name.split("-", 1)[1].split(".")[0])


def platform_jar() -> Path | None:
    """android.jar of the newest pinned platform."""
    s = sdk()
    if not s:
        return None
    names = [p.split("/", 1)[1] for p in pins()["androidSdk"]["packages"] if p.startswith("platforms/")]
    for name in sorted(names, key=platform_api, reverse=True):
        j = s / "platforms" / name / "android.jar"
        if j.exists():
            return j
    return None


def ndk_clang(api: int) -> Path | None:
    ndk = pinned_dir("ndk", quiet=True)
    if not ndk:
        return None
    host = "windows-x86_64" if WINDOWS else ("darwin-x86_64" if sys.platform == "darwin" else "linux-x86_64")
    name = f"aarch64-linux-android{api}-clang" + (".cmd" if WINDOWS else "")
    return ndk / "toolchains" / "llvm" / "prebuilt" / host / "bin" / name


def jar(prefix: str) -> Path:
    name = next(j["name"] for j in pins()["jars"] if j["name"].startswith(prefix))
    return TOOLS / name


def venv(name: str) -> Path:
    return WORK / name


def venv_exe(name: str, exe: str) -> Path:
    return WORK / name / VENV_BIN / f"{exe}{EXE}"


def path_dirs() -> list[Path]:
    """Directories for PATH, the pinned platform-tools first so a bare `adb` is the tested version."""
    dirs = [WORK / "platform-tools"]
    j = java_home()
    if j:
        dirs.append(j / "bin")
    s = sdk()
    if s:
        dirs.append(s / "cmdline-tools" / "latest" / "bin")
        for kind in ("build-tools", "ndk"):
            d = pinned_dir(kind, quiet=True)
            if d:
                dirs.append(d)
    dirs += [TOOLS / "jadx" / "bin", venv(".venv") / VENV_BIN, venv(".venv-frida") / VENV_BIN]
    if WINDOWS:
        dirs.append(Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "7-Zip")
    return [d for d in dirs if d.exists()]


def environment() -> dict[str, str]:
    """The variables a shell on this workstation needs (aosp-academy env / shell)."""
    env = {}
    s, j, ndk = sdk(), java_home(), pinned_dir("ndk", quiet=True)
    if s:
        env["ANDROID_HOME"] = str(s)
    if j:
        env["JAVA_HOME"] = str(j)
    if ndk:
        env["ANDROID_NDK_HOME"] = str(ndk)
    env["ADB"] = str(WORK / "platform-tools" / f"adb{EXE}")  # scrcpy and others honour $ADB
    env["ADB_TCP_KEEPALIVE_INTERVAL"] = os.environ.get("ADB_TCP_KEEPALIVE_INTERVAL", "60")  # see adb.py
    env["PATH"] = os.pathsep.join([str(d) for d in path_dirs()] + [os.environ.get("PATH", "")])
    return env
