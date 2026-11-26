"""The phone, through the pinned adb in work/platform-tools.

Every command that talks to the phone goes through this module, so the rules live in one place:
exactly one authorized device; root with whichever su the running system has; boot waits that
can't mistake the old system's "booted" for the new one's; DSU state from gsi_tool.
"""
from __future__ import annotations

import os
import re
import subprocess
import time

from .core import EXE, WORK, Failure, run, say, sleep

ADB = WORK / "platform-tools" / f"adb{EXE}"
FASTBOOT = WORK / "platform-tools" / f"fastboot{EXE}"

# adb sets a 1 s TCP keepalive on every 'adb connect' transport (socket_spec.cpp), and each probe
# wakes a phone that sleeps at the far end of the tunnel: about 3,000 wakeups an hour on 2026-11-25,
# with the phone awake a quarter of the time with its screen off. 60 s still notices a dead link
# within minutes. The adb server reads it when it starts, so it applies to servers this CLI starts
# and to anything run from 'aosp-academy shell'. A value already set wins.
KEEPALIVE_ENV = "ADB_TCP_KEEPALIVE_INTERVAL"
KEEPALIVE_DEFAULT = "60"
os.environ.setdefault(KEEPALIVE_ENV, KEEPALIVE_DEFAULT)


def adb(*args, check: bool = True, timeout: float | None = None) -> str:
    """Run adb and return its output (stdout and stderr together), stripped."""
    if not ADB.exists():
        raise Failure("platform-tools missing. Run: aosp-academy setup")
    try:
        p = run([ADB, *args], check=check, capture=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        # A network transport that's down (a reboot over the tunnel) makes adb hang rather than fail.
        if check:
            raise Failure(f"adb {' '.join(str(a) for a in args[:2])} timed out after {timeout} s")
        return ""
    return p.stdout.strip()


def quote(s: str) -> str:
    """Single-quote s for the phone's sh."""
    return "'" + s.replace("'", "'\\''") + "'"


def sh(command: str) -> str:
    """A shell command on the phone as the shell user; its output, stripped. Never raises on exit codes."""
    return adb("shell", command, check=False)


def prop(name: str) -> str:
    return sh(f"getprop {name}")


def devices() -> list[tuple[str, str]]:
    out = adb("devices")
    rows = []
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and not line.startswith("*"):
            rows.append((parts[0], parts[1]))
    return rows


def is_tcp(serial: str) -> bool:
    """A transport over the network (host:port, as adb connect lists it) rather than USB."""
    return bool(re.fullmatch(r"(\[[0-9a-fA-F:]+\]|[\w.-]+):\d+", serial))


def assert_one_device() -> None:
    """Exactly one phone. The same phone on USB and over Wi-Fi or the tunnel counts once: USB is
    used (ANDROID_SERIAL is set for every later adb call), or the network one when it's the only
    one. An ANDROID_SERIAL already set is respected."""
    authorized = [s for s, state in devices() if state == "device"]
    chosen = os.environ.get("ANDROID_SERIAL")
    if chosen:
        if chosen not in authorized:
            raise Failure(f"ANDROID_SERIAL is {chosen}, which isn't connected and authorized.")
        return
    if len(authorized) == 1:
        # Remembered for the waits: a network transport has to be reconnected after a reboot.
        os.environ["ANDROID_SERIAL"] = authorized[0]
        return
    if not authorized:
        raise Failure("No authorized device: connect the phone (USB, or adb connect over Wi-Fi or the tunnel).")
    phones = {adb("-s", s, "shell", "getprop ro.serialno", check=False) for s in authorized}
    if len(phones) != 1:
        raise Failure(f"{len(authorized)} devices connected: leave one, or choose one with ANDROID_SERIAL.")
    os.environ["ANDROID_SERIAL"] = next((s for s in authorized if not is_tcp(s)), authorized[0])


def root(command: str) -> str:
    """Run command as root, with the su the running system has.

    Two su flavours. Magisk's (the stock system) takes -c. AOSP's userdebug su (any DSU image built
    from source, this project's included) takes "su 0 <command>" and rejects -c with
    "invalid uid/gid '-c'". Magisk's form is tried first and AOSP's on that exact refusal. Nothing
    is cached: the phone can reboot between stock and an image while a session stays open.
    """
    q = quote(command)
    out = sh(f"su -c {q}")
    if "invalid uid/gid" not in out:
        return out
    return sh(f"su 0 sh -c {q}")


def has_root() -> bool:
    return "uid=0(" in root("id")


def wait_authorized(timeout: float = 600) -> None:
    """Wait until adb sees the phone as authorized, saying once what it waits for, for at most
    timeout seconds; then fail with what adb last saw and what to check.

    aosp-academy images set ro.adb.secure=1 and every DSU install starts with empty userdata, so a PC
    whose key isn't built into the image sees the phone as "unauthorized" until someone taps Allow.
    The limit matters over the network: a phone that rebooted out of reach (its tunnel down, or a
    stock system that doesn't answer this PC) never comes back by itself, and twice a deploy
    waited for one for ever.
    """
    told = False
    serial = os.environ.get("ANDROID_SERIAL", "")
    start = time.monotonic()
    state = ""
    while time.monotonic() - start < timeout:
        state = adb("get-state", check=False, timeout=20)
        if state == "device":
            return
        if is_tcp(serial):
            # A network transport doesn't come back by itself after a reboot: reconnect.
            adb("connect", serial, check=False, timeout=15)
        if "unauthorized" in state and not told:
            say('  >> Tap "Allow" on the phone\'s "Allow USB debugging?" prompt (tick "Always allow from this computer"). Waiting ...', "yellow")
            told = True
        sleep(2)
    raise Failure(_lost_message(serial, state, timeout))


def _lost_message(serial: str, state: str, timeout: float) -> str:
    """Why the phone didn't come back, and where to look, for the waits that give up."""
    seen = state.splitlines()[-1] if state else "no answer"
    if "unauthorized" in state:
        return (f"The phone is connected but not authorized after {int(timeout)} s: tap Allow on it, or build this PC's "
                "key into the image (work/adb_keys) or into the stock system's /data/misc/adb/adb_keys.")
    if is_tcp(serial):
        return (f"The phone hasn't answered on {serial} for {int(timeout)} s (adb: {seen}). It may be booting "
                "slowly, or out of reach: on the stock system its tunnel must answer this PC (dev_wireguard 1.3 or "
                "later), and on the image its tunnel needs Wi-Fi up. Connect it by USB to look "
                "(aosp-academy device report), then run the same command again. Nothing is lost by stopping here.")
    return f"The phone hasn't come back on USB for {int(timeout)} s (adb: {seen}). Check the cable, then run the same command again."


def wait_boot(timeout: int = 600, after_reboot: bool = False) -> int:
    """Wait for sys.boot_completed; return the seconds it took.

    after_reboot first waits for the old system to drop off USB, so its "booted" isn't taken for
    the new system's. The time counts from the call, the time off USB included.
    """
    start = time.monotonic()
    if after_reboot:
        try:
            adb("wait-for-disconnect", check=False, timeout=180)
        except subprocess.TimeoutExpired:
            pass
    wait_authorized(timeout=max(60, timeout - (time.monotonic() - start)))
    while time.monotonic() - start < timeout:
        # With a timeout: on a network transport that drops, a plain shell call hangs instead of failing.
        if adb("shell", "getprop sys.boot_completed", check=False, timeout=20) == "1":
            return round(time.monotonic() - start)
        sleep(5)
    raise Failure(f"The phone did not finish booting within {timeout} s.")


def reboot() -> None:
    adb("reboot", check=False)


def gsi_status() -> str:
    return root("gsi_tool status").strip()


def gsi_running() -> bool:
    """True while a DSU image is the running system.

    ro.gsid.image_running reads empty on this phone; gsi_tool's first line says "running" instead.
    """
    lines = gsi_status().splitlines()
    return bool(lines) and lines[0].strip() == "running"


def require_root_device() -> None:
    assert_one_device()
    if not has_root():
        raise Failure("Root (su) is required on the device.")
