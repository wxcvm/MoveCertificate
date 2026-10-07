#!/system/bin/sh
# Do NOT assume where your module will be located.
# ALWAYS use $MODDIR if you need to know where this script
# and module is placed.
# This will make sure your module will still work
# if Magisk change its mount point in the future
MODDIR=${0%/*}

. $MODDIR/sh/common.sh
. $MODDIR/sh/built-in.sh
. $MODDIR/sh/compatible.sh
. $MODDIR/sh/refresh.sh

print_log "start move cert !"
print_log "current sdk version is $sdk_version_number"
print_log "android release: $(getprop ro.build.version.release) / patch: $(getprop ro.build.version.security_patch)"
print_log "kernel su: $(command -v ksud || echo none) / magisk: $(command -v magisk || echo none)"

# 读取模式配置
read_mode_config
print_log "current mode is $CURRENT_MODE"

# Android 16/17 + builtin 模式的已知严重风险（上游 issue #74）：模块树里的 apex/
# 目录被 metamodule（Hybrid Mount / Mountify 等）overlay 到 /apex/com.android.conscrypt*
# 会干扰 apexd 的 APEX 激活，触发 apexd-failed → 开机重启循环（内核 panic
# "Attempted to kill init"），且只有禁用模块才能恢复。compatible 模式（默认）走
# tmpfs + bind，实测在 Android 17 上正常。
if [ "$sdk_version_number" -ge 36 ] && [ "$CURRENT_MODE" = "builtin" ]; then
    print_log "WARNING: builtin mode on SDK $sdk_version_number can cause apexd-failed boot loops when a metamodule overlays the module's apex/ tree (upstream issue #74). Use mode=compatible."
fi

# 先探测 nsenter 写法（Android 17 自带 toybox，旧代码的 util-linux 写法容易静默失效）
nsenter_probe

# 清理 builtin 模式遗留的挂载目录文件
clean_builtin_leftovers

# 记录系统原始证书列表
record_system_certs

# Android version <= 13 execute
if [ "$sdk_version_number" -le 33 ]; then
    if [ "$CURRENT_MODE" = "builtin" ]; then
        init_low_builtin_method
    else
        init_low_version
    fi
else
    if [ "$CURRENT_MODE" = "builtin" ]; then
        init_high_builtin_method
    else
        init_high_version
    fi
fi

# 结束自检：把结果也写一份到 /data/local/tmp，方便用 adb 直接看（模块目录里的
# 日志得先找到模块路径）
print_log "certificates installed"
if [ "$sdk_version_number" -le 33 ]; then
    verify_cert_mount $SYSTEM_CERT_DIR
else
    verify_cert_mount $APEX_CONSCRYPT_DIR
fi
cp -f "$LOG_PATH" /data/local/tmp/MoveCertificate.log 2>/dev/null