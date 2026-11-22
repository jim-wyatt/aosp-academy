# Instrumentation with Frida

[Frida](https://frida.re/) injects a JavaScript engine into a running process and lets you hook any function in it, Java or native, from the PC: log its arguments, change its return value, time it. A debugger stops the program to look at it; Frida watches it while it runs. On a device with root it's the fastest way to find out what your app, the framework or another app actually does.

!!! note "Your device, your processes"
    Hooking is a normal engineering activity on a device you own: debugging your own app against real hardware, reading how system services behave, checking what a preinstalled app does. Keep it to that. The [disclaimer](../reference/disclaimer.md) applies.

## What setup installed

Two halves, pinned to the same Frida version in `toolchain.json` (17.27.4; the two must match):

- **On the phone:** `frida-server`, an ARM64 program that runs as root and does the injecting. `aosp-academy setup` downloads it from Frida's GitHub release, checks its hash and unpacks it to `work/device-tools/frida-server`. It's pushed to the phone when you start it.
- **On the PC:** the `frida` and `frida-tools` Python packages in their own virtual environment, `work/.venv-frida`. `aosp-academy shell` (and `aosp-academy env`) put that venv on PATH, so `frida`, `frida-ps`, `frida-trace` and `frida-discover` are plain commands there.

`./aosp-academy check` confirms that the server was unpacked from the pinned download and that the venv's Frida is the same version; the device test (below) confirms the two work together on the phone.

## Start and stop the server

```sh
./aosp-academy device frida start   # push frida-server and start it as root
frida-ps -U                         # every process on the phone (-U: the USB device)
frida-ps -Ua                        # only apps, with their package names
./aosp-academy device frida stop    # stop it
```

`device frida start` needs root on the phone, and finds it with whichever `su` the running system has: AOSP's `su 0` on the image, Magisk's `su -c` on the stock system. It's idempotent: if a server is already running as root it says so and does nothing; one running as another user is stopped and replaced, because a server without root can list processes but not inject into most of them. The server runs from `/data/local/tmp/frida-server` until you stop it or the phone reboots.

A line reading `Unable to start idund: idund did not start listening` from `frida-ps` is noise: recent `frida-tools` first try to deploy a helper of their own over adb, find the pinned server already answering, and use it.

## Trace calls without writing code

`frida-trace` generates hooks from a pattern and prints every call with its arguments:

```sh
# Which files does Settings open? Trace libc's open() in the running Settings process.
frida-trace -U -i 'open' com.android.settings

# Which system properties does an app read at startup? Spawn it fresh and hook the Java API.
frida-trace -U -f com.example.firstapp -j 'android.os.SystemProperties!get'
```

`-i` matches native exported functions, `-j` matches `Class!method` in Java, `-f` spawns the app so you catch its startup, and a bare name or package attaches to the running process. The generated handlers land in a `__handlers__` folder in the current directory; edit one to log more or to change a return value, and `frida-trace` picks the edit up live.

## Write a hook

A script that logs every system property an app reads through the Java API:

```javascript title="props.js"
Java.perform(() => {
  const SystemProperties = Java.use('android.os.SystemProperties');
  SystemProperties.get.overload('java.lang.String').implementation = function (key) {
    const value = this.get(key);
    console.log(`SystemProperties.get(${key}) -> ${value}`);
    return value;
  };
});
```

```sh
frida -U -f com.example.firstapp -l props.js     # spawn the app with the hook installed
```

What `Java.use` returns is the real framework class in that process, so the same technique reaches hidden APIs, system services and your own app's internals. The [Frida JavaScript API](https://frida.re/docs/javascript-api/) is the reference; `Interceptor.attach` is the native-code equivalent of the Java override above.

## When to reach for it

| You want to know | Use |
| --- | --- |
| Which files, sockets or properties a process touches | `frida-trace -i` or `-j` |
| What a hidden or system API really returns | a `Java.use` hook that logs |
| Why your app behaves differently here than in the emulator | hook the call that differs and compare |
| How long one function takes, many times over | a hook that times it (simpleperf isn't available on this phone) |
| To stop and inspect state at one point | a debugger: [debugging](debugging.md) |
| Where time goes, system-wide | not Frida: [Perfetto](tracing.md) |

## Check it

`./aosp-academy device test` starts the server, runs `frida-ps -U`, passes if it sees more than 20 processes, and stops the server again. On the image it sees about 160.
