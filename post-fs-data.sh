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