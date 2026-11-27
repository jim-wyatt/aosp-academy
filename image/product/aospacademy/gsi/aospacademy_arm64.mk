#
# aospacademy_arm64: AOSP's arm64 GSI, with this project's apps, defaults and fixes.
#
# This is build/make/target/product/aosp_arm64.mk with three changes: the product-partition app set
# comes from aospacademy_product.mk instead of aosp_product.mk (so the AOSP apps the Fossify suite
# replaces are not built in at all), the Virtualization (AVF) packages are not inherited, and the
# settings aosp_arm64.mk keeps behind its
# `ifeq (aosp_arm64,$(TARGET_PRODUCT))` guard are applied unconditionally. Everything else is
# inherited from the same upstream makefiles, so the system partition is the stock GSI's.
#

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/generic_system.mk)
PRODUCT_ENFORCE_ARTIFACT_PATH_REQUIREMENTS := relaxed
$(call inherit-product, $(SRC_TARGET_DIR)/product/handheld_system_ext.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/telephony_system_ext.mk)
# Not inherited, unlike aosp_arm64.mk: packages/modules/Virtualization/apex/product_packages.mk.
# This SoC has no AVF (pKVM), so CompOS (com.android.compos), the virtualization feature file and
# the AVF properties are dead weight. com.android.virt itself stays: base_system.mk installs it
# and its framework-virtualization jar is on the classpath; without PRODUCT_AVF_ENABLED it builds
# its variant for devices without AVF.
$(call inherit-product, device/aospacademy/gsi/aospacademy_product.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/board/generic_arm64/device.mk)

AB_OTA_UPDATER := true
AB_OTA_PARTITIONS ?= system

MODULE_BUILD_FROM_SOURCE ?= true
$(call inherit-product, $(SRC_TARGET_DIR)/product/gsi_release.mk)
PRODUCT_SOONG_DEFINED_SYSTEM_IMAGE := aospacademy_system_image
USE_SOONG_DEFINED_SYSTEM_IMAGE := true
# The image module above lives in device/aospacademy/gsi/Android.bp: upstream's aosp_system_image
# mirrored without the apps the Fossify suite replaces and with this project's modules added.

PRODUCT_NAME := aospacademy_arm64
PRODUCT_DEVICE := generic_arm64
PRODUCT_BRAND := Android
PRODUCT_MODEL := aosp-academy on ARM64
PRODUCT_NO_BIONIC_PAGE_SIZE_MACRO := true

# --- this project's changes --------------------------------------------------------------------

# No boot animation: SurfaceFlinger skips the bootanimation service entirely, so the screen stays
# on the bootloader's splash until the lock screen. To replace the animation instead, drop this
# line and add a bootanimation.zip:
#   PRODUCT_COPY_FILES += device/aospacademy/gsi/bootanimation.zip:$(TARGET_COPY_OUT_PRODUCT)/media/bootanimation.zip
# The GSI's artifact-path rules forbid adding properties to the system partition
# (generic_system.mk), so this goes into the product partition's build.prop; property_get() reads all of them.
PRODUCT_PRODUCT_PROPERTIES += \
    debug.sf.nobootanimation=1

# Default time zone. Without a SIM the telephony suggestion is not applied (the US has several
# offsets), and AOSP without GMS has no location time-zone provider, so the device would otherwise
# start in GMT. A persist.* value in build.prop is only the default: a zone set in Settings or
# detected later is stored in /data and wins. Change it here for another region.
PRODUCT_PRODUCT_PROPERTIES += \
    persist.sys.timezone=America/New_York

# Charge limit in percent, as on stock with Battery protection on; 100 means charge to full (a hold already in place at exactly 100% lifts when the level next falls; docs/environment/image.md). Applied by
# init.aospacademy.rc (firstboot/) at boot and on every change. A value set with setprop is stored in
# /data and wins over this default.
PRODUCT_PRODUCT_PROPERTIES += \
    persist.aospacademy.charge_limit=80

# Every app debuggable over JDWP (and ptrace), so Android Studio's "Attach debugger to Android
# process" and `adb jdwp` reach any process, system_server and SystemUI included, without a
# debuggable APK. Zygote reads it once at start (Zygote.applyDebuggerSystemProperty), and only on
# userdebug (Build.IS_USERDEBUG); a user build ignores it. A persist.* default: setting it to 0 on
# the phone and rebooting turns it off. No access beyond what adb root already gives an
# authorised PC.
PRODUCT_PRODUCT_PROPERTIES += \
    persist.debug.dalvik.vm.jdwp.enabled=1

# ADB authorisation on, as on a user build: a PC must be allowed on the phone's screen before adb
# works. The GSI's system_ext build.prop sets ro.adb.secure=0 (build/make/target/board/
# gsi_system_ext.prop); init loads the product partition's build.prop last, so this value wins
# (validated on build 6). Each DSU install starts with empty userdata and no
# /data/misc/adb/adb_keys, so a PC not trusted below is asked about once per deploy;
# aosp-academy's boot wait (aosp_academy/adb.py) says so.
PRODUCT_PRODUCT_PROPERTIES += \
    ro.adb.secure=1

# PCs trusted in advance: the public keys in work/adb_keys (git-ignored; apply-local.sh copies it
# to device/aospacademy/gsi/adb_keys in the tree and removes the copy when the file is gone). Installed
# at /product/etc/security/adb_keys, which /adb_keys links to, and adbd trusts it alongside
# /data/misc/adb/adb_keys, so those PCs need no tap after a deploy. Kept for userdebug builds
# (RELEASE_BUILD_PURGE_PRODUCT_ADB_KEYS is false there). No key is in the repository, which is
# public; an image built with keys is specific to these machines, so it stays on them.
PRODUCT_ADB_KEYS := $(wildcard device/aospacademy/gsi/adb_keys)

# adb over Wi-Fi from the first boot: adbd reads persist.adb.tcp.port when it starts and listens on
# TCP 5555 as well as USB, so `aosp-academy adb-wifi` (adb connect <phone-ip>:5555) works with no
# `adb tcpip` step and no pairing. The same as the stock system's dev_adb_tcp module. Key
# authorisation still applies (ro.adb.secure=1 above): only a PC whose key is built in or allowed on
# the screen gets a shell. The port is reachable from the whole network, so use trusted networks.
# A persist.* default: `adb shell su 0 setprop persist.adb.tcp.port 0` and a reboot make it USB only.
PRODUCT_PRODUCT_PROPERTIES += \
    persist.adb.tcp.port=5555

# wg (wireguard/, built from the pinned wireguard-tools) for the optional tunnel: when aosp-academy
# deploy leaves a config in /data/local/aospacademy-wg, the aospacademy_wireguard service brings
# up wg0 at boot (kernel WireGuard; the 5.15 GKI has it built in). Without a config, nothing runs.
PRODUCT_PACKAGES += \
    aospacademy_wg

# The tunnel nudge (tunnelnudge/): a wake alarm every 2 minutes has WireGuard send the hub a
# keepalive, so a router that renumbers the phone's UDP mapping can't cut it off while it sleeps.
PRODUCT_PACKAGES += \
    aospacademy_tunnelnudge

# Our look and defaults: dark theme, gesture navigation, our wallpaper (from which Material You
# derives the system colours), Fossify Phone and Messages as the default dialer and SMS app.
# See overlay/ (a static framework RRO).
PRODUCT_PACKAGES += \
    AospAcademyFrameworkOverlay

# No Google endpoints for connectivity checks: NetworkStack's captive-portal probes go to
# GrapheneOS's public endpoints, which return the same 204 for any client (overlay/networkstack/,
# a static RRO on com.android.networkstack's NetworkStackConfig overlayable). Time comes from
# pool.ntp.org instead of time.android.com (config_ntpServers in the framework overlay).
PRODUCT_PACKAGES += \
    AospAcademyNetworkStackOverlay

# Fossify Launcher is the home screen. Launcher3QuickStep stays installed because SystemUI binds
# its quickstep service for gesture navigation and recents; the Launcher3 patch in image/patches/
# drops its HOME priority to -1, so the role controller's fallback holder is Fossify from the first
# boot, with no chooser. The first-boot service also assigns the role explicitly. (A preferred-apps
# file was tried first; with two equal-priority HOME activities the role controller ignored it.)

# The apps: the Fossify suite and nothing else on top of AOSP. Prebuilt APKs from F-Droid (hash-
# and signer-pinned in toolchain.json, copied into prebuilt/ by apply-local.sh), declared in
# prebuilt/Android.bp. They replace AOSP's Calendar, Camera2, Contacts, DeskClock, Dialer,
# Gallery2, Music, messaging and QuickSearchBox, which aospacademy_handheld_product.mk and
# aospacademy_product.mk leave out. There is no web browser: Browser2 stays out, and WebView still
# renders inside apps. Nothing updates these apps on the device; a new image with new pins does.
PRODUCT_PACKAGES += \
    FossifyLauncher \
    FossifyGallery \
    FossifyFileManager \
    FossifyDocuments \
    FossifyCalendar \
    FossifyContacts \
    FossifyPhone \
    FossifyMessages \
    FossifyClock \
    FossifyCalculator \
    FossifyNotes \
    FossifyMusicPlayer \
    FossifyCamera \
    FossifyVoiceRecorder \
    FossifyPaint \
    FossifyKeyboard

# The first-boot service (firstboot/): HOME role for Fossify Launcher, the development settings,
# the AOSP Files icon hidden, teal Fossify icons, and 16 MiB log buffers on every boot.
PRODUCT_PACKAGES += \
    aospacademy-firstboot \
    init.aospacademy.rc
