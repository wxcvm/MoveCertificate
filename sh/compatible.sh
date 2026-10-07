#!/system/bin/sh
MODDIR=${0%/*}

# 使用兼容模式

init_low_version() {

    # Android 13 or lower versions perform
    print_log "Use tmpfs $SYSTEM_CERT_DIR"
    print_log "Backup $SYSTEM_CERT_DIR"
    cp -u $SYSTEM_CERT_DIR/* $MODULE_CERT_DIR
    print_log "Backup user certs ($USER_CERT_DIRS)"
    merge_user_certs

    move_custom_cert
    fix_user_permissions
    compatible
    selinux_context=$(ls -Zd $SYSTEM_CERT_DIR | awk '{print $1}')
    mount -t tmpfs tmpfs $SYSTEM_CERT_DIR
    print_log "mount $SYSTEM_CERT_DIR status:$?"
    
    cp -f $MODULE_CERT_DIR/* $SYSTEM_CERT_DIR
    
    print_log "Install $SYSTEM_CERT_DIR status:$?"
    fix_system_permissions $SYSTEM_CERT_DIR
    print_log "certificates installed"
    [ "$(getenforce)" = "Enforcing" ] || return 0
    default_selinux_context=u:object_r:system_security_cacerts_file:s0
    if [ -n "$selinux_context" ] && [ "$selinux_context" != "?" ]; then
        chcon -R $selinux_context $SYSTEM_CERT_DIR
    else
        chcon -R $default_selinux_context $SYSTEM_CERT_DIR
    fi
    verify_cert_mount $SYSTEM_CERT_DIR
}


init_high_version(){

    print_log "Use mount $TEMP_DIR"
    mkdir -p $TEMP_DIR
    print_log "Backup $APEX_CONSCRYPT_DIR"
    cp -u $APEX_CONSCRYPT_DIR/* $MODULE_CERT_DIR
    print_log "Backup user certs ($USER_CERT_DIRS)"
    merge_user_certs
    move_custom_cert
    fix_user_permissions
    fix_system_permissions14 $MODULE_CERT_DIR
    compatible
    
    print_log "find system conscrypt directory"
    apex_dir=$(find /apex -type d -name "com.android.conscrypt@*" 2>/dev/null | head -n1)
    print_log "find conscrypt directory: $apex_dir"

    mount -t tmpfs tmpfs $TEMP_DIR
    print_log "mount $TEMP_DIR status:$?"
    cp -f $MODULE_CERT_DIR/* $TEMP_DIR
    fix_system_permissions14 $TEMP_DIR

    # 挂载目标：APEX 的两种路径（带/不带版本号），以及 Android 14+ 的
    # apexdata 可更新证书库——它一旦非空，Conscrypt 会优先读它，只覆盖 APEX
    # 就会"证书搬了却看不到"。旧代码完全没有处理这个目录。
    TARGETS="$APEX_CONSCRYPT_DIR"
    [ -n "$apex_dir" ] && TARGETS="$TARGETS $apex_dir/cacerts"
    [ -d "$APEXDATA_CERT_DIR" ] && TARGETS="$TARGETS $APEXDATA_CERT_DIR"
    print_log "mount targets:$TARGETS"

    for t in $TARGETS; do
        if [ ! -d "$t" ]; then
            print_log "SKIP missing target: $t"
            continue
        fi
        set_selinux_context "$t" "$TEMP_DIR"
        if mount -o bind $TEMP_DIR "$t"; then
            print_log "bind $TEMP_DIR -> $t OK"
        else
            print_log "ERROR bind $TEMP_DIR -> $t failed status:$?"
        fi
        verify_cert_mount "$t"
    done

    # 已经运行起来的进程（init / zygote / webview_zygote）在各自的 mount
    # namespace 里看不到上面的挂载，必须在它们内部再 bind 一次。
    # 旧代码只有一个 nsenter 写法且不检查返回值：在 toybox 上（Android 自带）
    # 失败时日志里什么都看不到，表现为"模块装了但证书没生效"。
    nsenter_probe
    for pid in 1 $(pgrep zygote) $(pgrep zygote64) $(pgrep webview_zygote); do
        # /proc/<pid>/ns/mnt 是符号链接，用 -e 而不是 -d（-d 恒为假，会把所有 pid
        # 都跳过——这正是"日志里只有 nsenter 配置、没有任何 bind 记录"的原因）
        [ -e /proc/$pid/ns/mnt ] || continue
        for t in $TARGETS; do
            if ns_run "$pid" mount --bind $TEMP_DIR "$t"; then
                print_log "ns($NSENTER_STYLE) pid=$pid bind $t OK"
            else
                print_log "ns($NSENTER_STYLE) pid=$pid bind $t FAILED"
            fi
        done
    done
}
