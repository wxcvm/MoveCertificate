#!/system/bin/sh
SKIPUNZIP=0
ui_print '- MoveCertificate: validated CA migration (Android 7-17)'
OLD_MODULE=/data/adb/modules/MoveCertificate
# Preserve configuration and learned names, never the old certificate cache.
mode=compatible
if [ -f "$OLD_MODULE/mode.conf" ]; then
    saved=$(sed -n 's/^mode=//p' "$OLD_MODULE/mode.conf" | head -n1 | tr -d '\r')
    case "$saved" in builtin|compatible) mode="$saved" ;; esac
fi
sdk=$(getprop ro.build.version.sdk)
case "$sdk" in ''|*[!0-9]*) abort 'Cannot determine Android SDK' ;; esac
if [ "$sdk" -ge 36 ] && [ "$mode" = builtin ]; then
    mode=compatible
    ui_print '- Android 16+: switching old builtin setting to compatible'
fi
printf 'mode=%s\n' "$mode" > "$MODPATH/mode.conf" || abort 'Cannot write mode configuration'
chmod 600 "$MODPATH/mode.conf"
if [ "$mode" = compatible ]; then
    touch "$MODPATH/skip_mount" || abort 'Cannot disable framework mounts'
fi
if [ -f "$OLD_MODULE/cert_names.json" ]; then
    cp "$OLD_MODULE/cert_names.json" "$MODPATH/cert_names.json" || abort 'Cannot preserve name cache'
fi
chmod 600 "$MODPATH/cert_names.json"
# Android owns cacerts-added. Do not create it or alter its permissions/labels.
if [ ! -e /data/local/tmp/cert ]; then
    mkdir -m 700 /data/local/tmp/cert || abort 'Cannot create custom certificate input directory'
elif [ -d /data/local/tmp/cert ] && [ ! -L /data/local/tmp/cert ]; then
    chown 0:0 /data/local/tmp/cert && chmod 700 /data/local/tmp/cert || abort 'Cannot secure custom certificate directory'
else
    abort 'Custom certificate path must be a directory, not a symlink'
fi
ui_print '- Existing user certificates are preserved; reboot after installation'
