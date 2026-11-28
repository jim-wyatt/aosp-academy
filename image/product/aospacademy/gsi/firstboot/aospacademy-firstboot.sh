#!/system/bin/sh
# aosp-academy first-boot service (see init.aospacademy.rc). Root, after boot completes, every boot;
# everything here checks a marker before it acts, so later boots cost nothing.
#
# It reports in two places that outlast the log buffers: $STATE/log gets every line with a time,
# and $STATE/status holds one line, "running" while it works and "done failures=<n>" at the end.
# aosp-academy deploy reads both (as root: adb shell su 0 cat ...). The same lines go to logcat
# under the tag aospacademy-firstboot.

TAG=aospacademy-firstboot
STATE=/data/local/aospacademy-firstboot
LOG="$STATE/log"
STATUS="$STATE/status"
mkdir -p "$STATE"
failures=0
restart_launcher=0

note() {
    log -t "$TAG" "$*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}
failed() { note "$* failed; will retry next boot"; failures=$((failures + 1)); }

# Charge-limit mode (init.aospacademy.rc starts it after boot and whenever the property changes):
# write persist.aospacademy.charge_limit to qpnp_adaptive_charge's upper_limit, the same single write
# Motorola's health HAL makes on stock. The module's own setter validates the value (1..100 above
# lower_limit, which stays -1: auto mode, as on stock); this checks it too. Reading parameters of
# the vendor charger modules in bulk has panicked this phone's kernel, so this touches two named
# files only: it writes upper_limit and never reads it (or lower_limit) back, and it checks the
# result through blocking, a read-only parameter with its own getter, which reports 1 while the
# module holds charging off. The result goes to the log and to $STATE/charge-limit for
# aosp-academy deploy. Verified by hand on the device first (2026-11-17): at 100% on the charger,
# blocking went 0 -> 1 and the battery status to "Not charging", as on stock with protection on.
#
# init's `start` does nothing for a oneshot that is still running, so a setprop during the 30 s
# wait would be lost. After the wait the property is read again, and a changed value is applied
# in turn. The result file is removed first: it lives in /data and outlasts reboots, and
# aosp-academy deploy must not read the previous boot's result as this one's.
if [ "$1" = charge-limit ]; then
    mod=/sys/module/qpnp_adaptive_charge/parameters
    rm -f "$STATE/charge-limit"
    result() { note "charge limit: $*"; echo "$*" > "$STATE/charge-limit"; exit 0; }
    v="$(getprop persist.aospacademy.charge_limit)"
    while :; do
        case "$v" in
            ''|*[!0-9]*) result "'$v' is not a number; left unchanged" ;;
        esac
        { [ "$v" -lt 50 ] || [ "$v" -gt 100 ]; } && result "$v is outside 50..100; left unchanged"
        [ -e "$mod/upper_limit" ] || result "qpnp_adaptive_charge not present; left unchanged"
        echo "$v" > "$mod/upper_limit" 2>/dev/null || result "writing $v to upper_limit failed"
        sleep 30    # the module re-evaluates on its next battery update
        now="$(getprop persist.aospacademy.charge_limit)"
        [ "$now" = "$v" ] && break
        note "charge limit: property changed to '$now' while $v was applied; applying it"
        v="$now"
    done
    result "upper_limit=$v, blocking=$(cat "$mod/blocking" 2>/dev/null) (1 = holding charge off)"
fi

# Wired networks beside the full tunnel: keep each Ethernet network Android brings up (ethN: a USB
# Ethernet adapter, or a USB device that is a network, such as an ADALM-Pluto SDR in NCM mode)
# local, as rule 8995 keeps the Wi-Fi subnet local. One rule per network at 8996 looks
# in that network's own table without its default route, so only its own subnet leaves by it and
# everything else still goes into the tunnel. The tables come and go with the device, and a rule
# left behind names a number instead of the table, so this replaces the 8996 rules whenever they
# don't match the tables that exist. It touches 8996 only and never restarts the tunnel.
wired_bypass() {
    want=""
    for i in $(ip -o link show 2>/dev/null | sed -n 's/^[0-9]*: \(eth[0-9][0-9]*\)[:@].*/\1/p'); do
        ip -4 route show table "$i" 2>/dev/null | grep -q . && want="$want $i"
    done
    want="$(for i in $want; do echo "$i"; done | sort | tr '\n' ' ')"
    have="$(ip -4 rule show priority 8996 2>/dev/null | sed -n 's/.*lookup \([^ ]*\).*/\1/p' | sort | tr '\n' ' ')"
    [ "$want" = "$have" ] && return 0
    for fam in -4 -6; do
        while ip "$fam" rule del priority 8996 2>/dev/null; do :; done
        for i in $want; do
            ip "$fam" rule add lookup "$i" suppress_prefixlength 0 priority 8996 2>/dev/null
        done
    done
    note "wired networks kept off the tunnel: ${want:-none}"
}

# WireGuard mode (init.aospacademy.rc starts it after boot; aosp-academy deploy starts it after
# pushing a config): bring up wg0 from $WG_DIR/wg0.conf (wg setconf format: the phone's private key
# and the hub peer) and $WG_DIR/wg0.env (ADDRESS4=, ADDRESS6=, ROUTES4=, ROUTES6=; routes
# space-separated). Both come from the device node; without them it does nothing. Android routes by
# policy, per network, so the tunnel's subnets get a table of their own (1999) and a rule ahead of
# the per-network rules. The result goes to $WG_DIR/status for the deploy report.
if [ "$1" = wireguard ]; then
    WG_DIR=/data/local/aospacademy-wg
    [ -f "$WG_DIR/wg0.conf" ] && [ -f "$WG_DIR/wg0.env" ] || exit 0
    umask 077
    result() { note "wireguard: $*"; echo "$*" > "$WG_DIR/status"; exit 0; }
    wg=/product/bin/wg
    [ -x "$wg" ] || wg="$WG_DIR/wg"   # a wg pushed by hand, for trying this on an image without one
    [ -x "$wg" ] || result "failed: no wg binary"
    # tr -d '\r': a file written on Windows has CRLF line ends, and "1\r" is not "1" (a CRLF
    # wg0.env once left the tunnel without routes, and the phone unreachable).
    val() { sed -n "s/^$1=//p" "$WG_DIR/wg0.env" | head -n 1 | tr -d '\r'; }
    a4="$(val ADDRESS4)"; a6="$(val ADDRESS6)"; r4="$(val ROUTES4)"; r6="$(val ROUTES6)"
    full="$(val FULL)"; mtu="$(val MTU)"; dns4="$(val DNS4)"; dns6="$(val DNS6)"
    # Start from nothing: remove what an earlier run set (split or full), so every run ends in
    # exactly the state its wg0.env describes, and a run with the old files undoes a new one.
    for fam in -4 -6; do
        for prio in 8990 8995 8996 9000; do
            while ip "$fam" rule del priority "$prio" 2>/dev/null; do :; done
        done
        ip "$fam" route flush table 1999 2>/dev/null
    done
    iptables -t nat -D OUTPUT -j aa_dns 2>/dev/null; iptables -t nat -F aa_dns 2>/dev/null; iptables -t nat -X aa_dns 2>/dev/null
    iptables -t nat -D POSTROUTING -j aa_snat 2>/dev/null; iptables -t nat -F aa_snat 2>/dev/null; iptables -t nat -X aa_snat 2>/dev/null
    ip6tables -D OUTPUT -j aa_dns6 2>/dev/null; ip6tables -F aa_dns6 2>/dev/null; ip6tables -X aa_dns6 2>/dev/null
    ip link del wg0 2>/dev/null
    ip link add wg0 type wireguard || result "failed: the kernel refused a wireguard link"
    "$wg" setconf wg0 "$WG_DIR/wg0.conf" || { ip link del wg0; result "failed: wg setconf"; }
    [ -n "$a4" ] && ip addr add "$a4" dev wg0
    [ -n "$a6" ] && ip -6 addr add "$a6" dev wg0
    [ -n "$mtu" ] && ip link set wg0 mtu "$mtu"
    ip link set wg0 up || result "failed: wg0 did not come up"
    if [ "$full" = 1 ]; then
        # All traffic through the tunnel (FULL=1). wg0.conf's AllowedIPs must be 0.0.0.0/0, ::/0.
        ep="$(sed -n 's/^Endpoint *= *//p' "$WG_DIR/wg0.conf" | head -n 1 | tr -d '\r ')"
        ep="${ep%:*}"; ep="${ep#[}"; ep="${ep%]}"
        [ -n "$ep" ] || result "failed: no Endpoint in wg0.conf"
        case "$ep" in *:*) epfam=-6 ;; *) epfam=-4 ;; esac
        # 0. Wait for Wi-Fi's own routing table. At boot, with a saved network, this can run before
        #    netd has created it (the table "wlan0" doesn't resolve yet), and then rules 1 and 2
        #    fail: the tunnel's own packets to the hub go into wg0 itself, nothing ever handshakes,
        #    and the kill switch below blocks everything, adb included. That happened on build 22's
        #    second boot. Until the table is there, nothing has been routed into the tunnel, so
        #    giving up leaves the phone on plain Wi-Fi.
        t=0
        until ip -4 route show table wlan0 2>/dev/null | grep -q '^default'; do
            [ "$t" -ge 120 ] && result "failed: no Wi-Fi routing table (wlan0) after 120 s; not routing into the tunnel"
            sleep 2; t=$((t + 2))
        done
        # 1. The tunnel's own encrypted packets to the hub leave by Wi-Fi, as before.
        ip "$epfam" rule add to "$ep" lookup wlan0 priority 8990 \
            || result "failed: no rule for the hub's endpoint; not routing into the tunnel"
        # 2. The Wi-Fi network's own subnet stays local (the router, DHCP, neighbour discovery):
        #    the Wi-Fi table without its default route.
        ip -4 rule add lookup wlan0 suppress_prefixlength 0 priority 8995 \
            || result "failed: no rule for the Wi-Fi subnet; not routing into the tunnel"
        ip -6 rule add lookup wlan0 suppress_prefixlength 0 priority 8995
        # 2b. Wired networks (a USB SDR, a USB Ethernet adapter) stay local the same way; the
        #     watch below keeps these rules current as devices come and go.
        wired_bypass
        # 3. Everything else into the tunnel, ahead of Android's per-network rules. The unreachable
        #    default behind wg0's is the kill switch: if wg0 goes, its route goes with it, and
        #    nothing falls back to Wi-Fi.
        for fam in -4 -6; do
            ip "$fam" route replace default dev wg0 table 1999
            ip "$fam" route add unreachable default metric 9999 table 1999
            ip "$fam" rule add from all lookup 1999 priority 9000
        done
        # 4. Anything leaving through wg0 gets the tunnel address as its source. A socket can pick
        #    its source before a DNAT below moves it into the tunnel (a query to the Wi-Fi router's
        #    DNS starts as 192.168.x), and the hub drops packets from this peer with any other source.
        iptables -t nat -N aa_snat && iptables -t nat -A aa_snat -o wg0 -j MASQUERADE \
            && iptables -t nat -I POSTROUTING -j aa_snat
        # 5. DNS: every plain IPv4 query goes to the hub's resolver (the hub drops port 53 to
        #    anywhere else), whichever server the Wi-Fi network hands out. This kernel has no IPv6
        #    nat table, so IPv6 queries to any other server are rejected instead, and Android's
        #    resolver falls back to IPv4. Private DNS (DoT) would bypass the hub, so it goes off.
        [ -n "$dns4" ] && iptables -t nat -N aa_dns && iptables -t nat -I OUTPUT -j aa_dns \
            && iptables -t nat -A aa_dns -p udp --dport 53 -j DNAT --to-destination "$dns4" \
            && iptables -t nat -A aa_dns -p tcp --dport 53 -j DNAT --to-destination "$dns4"
        ip6tables -N aa_dns6 && ip6tables -I OUTPUT -j aa_dns6 \
            && ip6tables -A aa_dns6 -p udp --dport 53 ${dns6:+! -d "$dns6"} -j REJECT \
            && ip6tables -A aa_dns6 -p tcp --dport 53 ${dns6:+! -d "$dns6"} -j REJECT
        settings put global private_dns_mode off >/dev/null 2>&1
        ip rule | grep -q "lookup 1999" || result "failed: no routing rule for the tunnel"
        result "up ${a4%/*}, all traffic"
    fi
    for r in $r4; do
        ip route replace "$r" dev wg0 table 1999
        ip rule del to "$r" lookup 1999 2>/dev/null
        ip rule add to "$r" lookup 1999 priority 9000
    done
    for r in $r6; do
        ip -6 route replace "$r" dev wg0 table 1999
        ip -6 rule del to "$r" lookup 1999 2>/dev/null
        ip -6 rule add to "$r" lookup 1999 priority 9000
    done
    result "up ${a4%/*}"
fi

# WireGuard watch mode (init.aospacademy.rc keeps it running after boot): the full tunnel's two
# bypass rules point at Wi-Fi's routing table, and that table can come and go under them. When
# Wi-Fi drops and comes back, or comes up only after the boot-time setup gave up waiting for it,
# the rules are missing or name a table number that no longer resolves to wlan0 (ip rule then
# shows the number instead of the name). This checks both rules and wg0 whenever the routing
# rules or routes change, and runs the wireguard mode again if any is wrong. It is driven by
# `ip monitor`, not a timer: an idle phone suspends, and a sleep doesn't advance while it is
# suspended, but a route change wakes the reader at once. It waits for the boot-time run to finish
# first (its status file), so the two never overlap, and checks once before the first event.
if [ "$1" = wireguard-watch ]; then
    WG_DIR=/data/local/aospacademy-wg
    until [ -f "$WG_DIR/status" ]; do sleep 10; done
    check() {
        [ -f "$WG_DIR/wg0.conf" ] && [ -f "$WG_DIR/wg0.env" ] || return 0
        [ "$(sed -n 's/^FULL=//p' "$WG_DIR/wg0.env" | head -n 1 | tr -d '\r')" = 1 ] || return 0
        # A wired network came or went: adjust its 8996 rule alone, with or without Wi-Fi.
        wired_bypass
        # No Wi-Fi: nothing to repair yet, and nothing reaches the hub anyway.
        ip -4 route show table wlan0 2>/dev/null | grep -q '^default' || return 0
        rules="$(ip -4 rule 2>/dev/null)"
        echo "$rules" | grep -q '^8990:.*lookup wlan0' && echo "$rules" | grep -q '^8995:.*lookup wlan0' \
            && ip link show wg0 >/dev/null 2>&1 && return 0
        note "wireguard-watch: Wi-Fi changed under the tunnel; setting it up again"
        "$0" wireguard
    }
    check
    # A check per event line, with no debounce: a read -t or sleep is a timer, and timers stand
    # still while the phone is suspended. The check costs three ip calls, and once the setup has
    # run, the events it caused itself all pass it.
    ip monitor rule route 2>/dev/null | while read -r _; do
        check
    done
    exit 0   # the monitor ended; init restarts the service
fi

# Tunnel-nudge mode (aospacademy-tunnelnudge runs it on a wake alarm, every
# persist.aospacademy.tunnel_nudge seconds): have WireGuard send each peer a keepalive now. The
# kernel sends one at once only when a peer's persistent keepalive goes from off to on
# (wireguard/netlink.c, set_peer), so this turns it off and back to the value it had. The packet
# goes out from the phone's own port, so a home router that dropped or renumbered the mapping makes
# a new one, and the hub learns the new endpoint from it. Silent: it runs every few minutes.
if [ "$1" = tunnel-nudge ]; then
    WG_DIR=/data/local/aospacademy-wg
    wg=/product/bin/wg
    [ -x "$wg" ] || wg="$WG_DIR/wg"
    "$wg" show wg0 persistent-keepalive 2>/dev/null | while read -r peer every; do
        case "$every" in ''|off|*[!0-9]*) continue ;; esac
        "$wg" set wg0 peer "$peer" persistent-keepalive 0
        "$wg" set wg0 peer "$peer" persistent-keepalive "$every"
    done
    exit 0
fi

echo running > "$STATUS"
note "start"

# 0. Provisioning staged by aosp-academy deploy. Every DSU install starts with empty data, so the
#    deploy, on the stock system, leaves the Wi-Fi network (wifi.env: SSID=, SECURITY=, PASSPHRASE=)
#    and the tunnel config (wg0.conf, wg0.env) in /metadata/aospacademy: root-only files on the
#    metadata partition, which stock and the image share and a DSU install doesn't touch. They are
#    used here and then deleted at once, whether or not they worked, so no secret stays there. The
#    passphrase goes to Wi-Fi only, never into a log.
STAGE=/metadata/aospacademy
if [ -d "$STAGE" ]; then
    if [ -f "$STAGE/wifi.env" ]; then
        sval() { sed -n "s/^$1=//p" "$STAGE/wifi.env" | head -n 1 | tr -d '\r'; }
        cmd wifi set-wifi-enabled enabled >/dev/null 2>&1
        sleep 3
        if cmd wifi connect-network "$(sval SSID)" "$(sval SECURITY)" "$(sval PASSPHRASE)" >/dev/null 2>&1; then
            note "staged Wi-Fi network added"
        else
            failed "staged Wi-Fi network"
        fi
    fi
    if [ -f "$STAGE/wg0.conf" ] && [ -f "$STAGE/wg0.env" ]; then
        if ( umask 077; mkdir -p /data/local/aospacademy-wg && cp "$STAGE/wg0.conf" "$STAGE/wg0.env" /data/local/aospacademy-wg/ ); then
            note "staged tunnel config installed"
            "$0" wireguard   # the boot-time service may have run before the config was here
        else
            failed "staged tunnel config"
        fi
    fi
    rm -rf "$STAGE"
    [ -e "$STAGE" ] && failed "removing $STAGE"
fi

# 1. Fossify Launcher ("Launcher") as the home screen. Quickstep (AOSP's Launcher3, which stays
#    because SystemUI binds its quickstep service for gesture navigation and recents) is patched to
#    HOME priority -1, so the role controller already falls back to Fossify before this runs. Assign
#    the HOME role once anyway, explicitly; a launcher the user picks later (Quickstep included) is
#    respected.
HOME_PKG=org.fossify.home
if [ ! -e "$STATE/home-role" ] && pm path "$HOME_PKG" >/dev/null 2>&1; then
    if cmd role add-role-holder android.app.role.HOME "$HOME_PKG" 0 >/dev/null 2>&1; then
        touch "$STATE/home-role"
        note "HOME role -> $HOME_PKG"
    else
        failed "HOME role assignment"
    fi
fi

# 2. Development-target settings, the same values 'aosp-academy device settings' applies on the stock
#    system: Developer options shown, the screen kept on while charging (Stay awake: AC, USB,
#    wireless and dock, as the toggle writes), no animations (UI tests expect it, screens settle
#    at once), no verification scan of adb installs, no expiry of an authorised PC's ADB key, and
#    manual brightness at 64 of 255 (the OLED panel stays on while charging; it still dims when idle).
#    Entries are global settings unless prefixed system/.
#    Set once, as defaults: a value changed later in Developer options is kept. SettingsProvider
#    has resource defaults for only some of them in this tag, so they are all set here, in one place.
if [ ! -e "$STATE/dev-settings" ]; then
    ok=1
    for kv in development_settings_enabled=1 stay_on_while_plugged_in=15 window_animation_scale=0 transition_animation_scale=0 animator_duration_scale=0 \
              verifier_verify_adb_installs=0 adb_allowed_connection_time=0 \
              system/screen_brightness_mode=0 system/screen_brightness=64; do
        case "$kv" in system/*) ns=system; kv="${kv#system/}";; *) ns=global;; esac
        k="${kv%%=*}"; v="${kv#*=}"
        settings put "$ns" "$k" "$v" >/dev/null 2>&1
        [ "$(settings get "$ns" "$k" 2>/dev/null)" = "$v" ] || { ok=0; note "setting $ns $k=$v did not stick"; }
    done
    if [ "$ok" = 1 ]; then touch "$STATE/dev-settings"; note "development settings applied"
    else failed "development settings"; fi
fi

# 3. Hide the app-drawer icons of AOSP apps that stay for what they do in the background, where a
#    Fossify app is the one to open. Only the launcher entry is disabled, once per entry (neither
#    is gated on a resource in this tag); pm enable on the same component brings an icon back.
#      Files      DocumentsUI stays: it is the system file picker behind every open, get-content
#                 and save dialog (.picker.PickActivity), Fossify's included. Fossify File
#                 Manager is the file app. The icon is the activity-alias .LauncherActivity.
#      Keyboard   LatinIME stays as the fallback keyboard. Its settings are still reachable from
#                 Settings, System, Keyboard. Fossify Keyboard is the keyboard app.
for entry in "files com.android.documentsui/.LauncherActivity" \
             "keyboard com.android.inputmethod.latin/.setup.SetupActivity"; do
    name="${entry%% *}"; component="${entry#* }"
    [ -e "$STATE/$name-icon" ] && continue
    pm path "${component%%/*}" >/dev/null 2>&1 || continue
    if pm disable "$component" >/dev/null 2>&1; then
        touch "$STATE/$name-icon"; restart_launcher=1
        note "launcher icon hidden: $component"
    else
        failed "hiding the launcher icon $component"
    fi
done

# 4. Fossify app icons in teal, to match the image's wallpaper and accent (the suite's default is
#    green). Inside the apps Fossify already follows the system's Material You colours on
#    Android 12+; the launcher icon colour is a separate per-app choice, implemented as one
#    activity-alias per colour (SplashActivity.<Colour>) plus two preferences the app reconciles
#    on every start (app_icon_color and last_icon_color in shared_prefs/Prefs.xml). Setting all
#    three together is exactly what the app's own Customize screen does. Done once per app, so a
#    colour the user picks later is never overridden.
ICON_ALIAS=Teal
ICON_COLOR=-16746133        # md_teal_700, #ff00796b, as the signed int Android stores
for pkg in $(pm list packages org.fossify. | sed 's/^package://'); do
    marker="$STATE/$pkg.icon"
    [ -e "$marker" ] && continue
    data="/data/data/$pkg"
    [ -d "$data" ] || continue
    pm enable "$pkg/$pkg.activities.SplashActivity.$ICON_ALIAS" >/dev/null 2>&1 || { failed "icon colour for $pkg"; continue; }
    pm disable "$pkg/$pkg.activities.SplashActivity.Green" >/dev/null 2>&1
    am force-stop "$pkg"
    prefs="$data/shared_prefs"; f="$prefs/Prefs.xml"; uid=$(stat -c %u "$data")
    mkdir -p "$prefs"
    if [ -f "$f" ]; then
        sed -i '/name="app_icon_color"/d; /name="last_icon_color"/d' "$f"
        sed -i "s#</map>#    <int name=\"app_icon_color\" value=\"$ICON_COLOR\" />\n    <int name=\"last_icon_color\" value=\"$ICON_COLOR\" />\n</map>#" "$f"
    else
        printf "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n    <int name=\"app_icon_color\" value=\"%s\" />\n    <int name=\"last_icon_color\" value=\"%s\" />\n</map>\n" "$ICON_COLOR" "$ICON_COLOR" > "$f"
    fi
    chown -R "$uid:$uid" "$prefs"; chmod 771 "$prefs"; chmod 660 "$f"
    restorecon -RF "$prefs" >/dev/null 2>&1
    touch "$marker"; restart_launcher=1
    note "icon colour $ICON_ALIAS for $pkg"
done

# 4b. Fossify Clock lets the screen turn off. Its "Prevent phone from sleeping while the app is in
#     the foreground" setting (prevent_phone_from_sleeping) is on by default and holds the screen on
#     with FLAG_KEEP_SCREEN_ON; on 2026-11-25 the clock left open kept the screen on for seven hours.
#     Off once, as a default (step 4 above has created Prefs.xml), so turning it on later in the
#     app's settings sticks.
CLOCK=org.fossify.clock
f=/data/data/$CLOCK/shared_prefs/Prefs.xml
if [ ! -e "$STATE/clock-sleep" ] && [ -f "$f" ]; then
    am force-stop "$CLOCK"
    sed -i '/name="prevent_phone_from_sleeping"/d' "$f"
    sed -i 's#</map>#    <boolean name="prevent_phone_from_sleeping" value="false" />\n</map>#' "$f"
    uid=$(stat -c %u "/data/data/$CLOCK"); chown "$uid:$uid" "$f"; chmod 660 "$f"
    restorecon -F "$f" >/dev/null 2>&1
    touch "$STATE/clock-sleep"; note "Fossify Clock no longer keeps the screen on"
fi

# 5. Bluetooth off. Android turns it on at boot by default (BluetoothManagerService, SYSTEM_BOOT);
#    a development phone on a desk has nothing to pair with. Bluetooth scanning (apps scanning
#    for beacons while Bluetooth is off, ble_scan_always_enabled) goes off too. Done once, as a
#    default: Android keeps the adapter's last state across reboots, so switching it on later in
#    Settings or Quick Settings sticks.
if [ ! -e "$STATE/bluetooth-off" ]; then
    settings put global ble_scan_always_enabled 0 >/dev/null 2>&1
    cmd bluetooth_manager disable >/dev/null 2>&1
    timeout 20 cmd bluetooth_manager wait-for-state:STATE_OFF >/dev/null 2>&1
    if [ "$(settings get global bluetooth_on 2>/dev/null)" = 0 ] && [ "$(settings get global ble_scan_always_enabled 2>/dev/null)" = 0 ]; then
        touch "$STATE/bluetooth-off"; note "bluetooth off"
    else
        failed "bluetooth off"
    fi
fi

# The launcher caches icons and its app list; restart it so the changes above show.
if [ "$restart_launcher" = 1 ]; then
    home="$(cmd role get-role-holders android.app.role.HOME 2>/dev/null)"
    [ -n "$home" ] && am force-stop "$home"
fi

note "done failures=$failures"
echo "done failures=$failures" > "$STATUS"
exit 0
