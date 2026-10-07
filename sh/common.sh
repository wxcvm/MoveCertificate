#!/system/bin/sh
MODDIR=${0%/*}

sdk_version=$(getprop ro.build.version.sdk)
# debug
#sdk_version=34
sdk_version_number=$(expr "$sdk_version" + 0)

# add logcat
LOG_PATH="$MODDIR/install.log"
LOG_TAG="iyue"

## Keep only one up-to-date log
echo "[$LOG_TAG] Keep only one up-to-date log" >$LOG_PATH
print_log() {
    echo "[$LOG_TAG] $@" >>$LOG_PATH
}

# ==================== 模式配置读取 ====================
# 配置文件路径：$MODDIR/mode.conf
# 格式：mode=compatible 或 mode=builtin
# 默认值：compatible（向后兼容）
CONFIG_FILE="$MODDIR/mode.conf"

CURRENT_MODE="compatible"

read_mode_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_log "Config file $CONFIG_FILE not found, using default mode: compatible"
        CURRENT_MODE="compatible"
        return 0
    fi

    # 读取第一行非空内容作为模式配置
    local raw
    raw=$(grep -m1 '^[[:space:]]*mode=' "$CONFIG_FILE" 2>/dev/null)

    if [ -z "$raw" ]; then
        print_log "Config file $CONFIG_FILE has no valid 'mode=' entry, using default: compatible"
        CURRENT_MODE="compatible"
        return 0
    fi

    # 提取 = 号右边的值，移除首尾空白，转为小写
    local mode_val
    mode_val=$(echo "$raw" | sed 's/^[[:space:]]*mode[[:space:]]*=[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')

    case "$mode_val" in
        compatible|builtin)
            CURRENT_MODE="$mode_val"
            print_log "Read mode config: $CURRENT_MODE"
            ;;
        *)
            print_log "Unknown mode '$mode_val' in $CONFIG_FILE, falling back to default: compatible"
            CURRENT_MODE="compatible"
            ;;
    esac
}

# PATH DIR
## MOBULE DIR
MODULE_CERT_DIR=$MODDIR/certificates

## Custom certificate directory
CUSTOM_CERT_DIR=/data/local/tmp/cert

## User certificate directory
USER_CERT_DIR=/data/misc/user/0/cacerts-added

## Every user's certificate directory.
## The store is per Android user, and the module only ever looked at user 0, so
## certificates installed by a work profile or a secondary user were ignored.
## USER_CERT_DIR stays as the user-0 compatibility alias.
USER_CERT_DIRS=""
for _ucd in /data/misc/user/*/cacerts-added; do
    [ -d "$_ucd" ] && USER_CERT_DIRS="$USER_CERT_DIRS $_ucd"
done
[ -n "$USER_CERT_DIRS" ] || USER_CERT_DIRS="$USER_CERT_DIR"

## System certificate directory
SYSTEM_CERT_DIR=/system/etc/security/cacerts

## Apex conscrypt directory
APEX_CONSCRYPT_DIR=/apex/com.android.conscrypt/cacerts

## Conscrypt's *updateable* trust store (Android 14+). Conscrypt reads this one
## when it is populated, and then an overlay over the APEX alone is ignored -
## the blind spot that could make "moved" certificates invisible on 14+ builds.
APEXDATA_CERT_DIR=/data/misc/apexdata/com.android.conscrypt/cacerts

## Module built-in 
MODULE_SYSTEM_CERT_DIR=$MODDIR/system/etc/security/cacerts

## Module Apex conscrypt directory
MODULE_APEX_CONSCRYPT_DIR=$MODDIR/apex/com.android.conscrypt/cacerts
# 模块内带版本号的 conscrypt 挂载目录（对应系统 /apex/com.android.conscrypt@版本号）
# basename 去掉 find 返回的 /apex 前缀，head -n1 防止多版本目录导致换行；
# find 为空时路径落在 $MODDIR/apex/cacerts（目录不存在，后续操作自然失败，不会误伤模块根目录）
APEX_CONSCRYPT_NUM_NAME=$(basename "$(find /apex -type d -name 'com.android.conscrypt@*' 2>/dev/null | head -n1)")
MODULE_APEX_CONSCRYPT_NUM_DIR=$MODDIR/apex/$APEX_CONSCRYPT_NUM_NAME/cacerts

## Temporary directory
# FULL_PATH=$(mktemp -d)
# RANDOM_NAME=$(basename "$FULL_PATH")
TEMP_DIR=/mnt/instaler

move_custom_cert() {
    if [ -d "$CUSTOM_CERT_DIR" ] && [ -n "$(ls -A "$CUSTOM_CERT_DIR" 2>/dev/null)" ]; then

        # 这个目录曾经是 0777（customize.sh 用 -m 777 创建，设备上实测确实是
        # drwxrwxrwx）：任何应用都能往里投一张 CA，而这里的内容会被装进系统信任库
        # —— 一条提权路径。这里收紧目录权限，并且只接受 root 拥有的文件。
        chmod 700 "$CUSTOM_CERT_DIR" 2>/dev/null
        _mc_installed=0
        for cert_file in "$CUSTOM_CERT_DIR"/*; do
            [ -f "$cert_file" ] || continue
            _mc_owner=$(ls -n "$cert_file" 2>/dev/null | awk '{print $3}')
            if [ "$_mc_owner" != "0" ]; then
                print_log "SKIP $(basename "$cert_file"): not owned by root (uid=$_mc_owner)"
                continue
            fi
            byte=$(head -c1 "$cert_file" | od -An -tx1 | tr -d ' \n')
            if [ "$byte" != "30" ]; then
                print_log "$(basename "$cert_file") is not a der certificate, needs encoding conversion, deleting it"
                rm -f "$cert_file"
                continue
            fi
            cp -f "$cert_file" "$MODULE_CERT_DIR"
            cp -f "$cert_file" "$USER_CERT_DIR"
            _mc_installed=$((_mc_installed + 1))
        done
        print_log "installed $_mc_installed certificate(s) from $CUSTOM_CERT_DIR"
    else
        print_log "The directory $CUSTOM_CERT_DIR is empty."
    fi
    print_log "Install $CUSTOM_CERT_DIR status:$?"
}

fix_user_permissions() {
    # "Fix permissions of the system certificate directory"
    # 644 而不是 666：证书不需要任何人可写（原值让这些文件 world-writable，
    # 一旦路径可达就成了替换系统信任内容的入口）
    chown -R root:root $USER_CERT_DIR/
    chmod -R 644 $USER_CERT_DIR/
    chown system:system $USER_CERT_DIR
    chmod 755 $USER_CERT_DIR
    print_log "fix user certificate permissions status:$?"
}

fix_system_permissions() {
    chown root:root $1
    chown -R root:root $1
    chmod -R 644 $1
    chmod 755 $1
    chcon u:object_r:system_file:s0 $1/*
    touch -t 200901010800 $1/*
    touch -t 200901010800 $1
    print_log "fix permissions $1 status:$?"
}

fix_system_permissions14() {
    chown -R system:system "$1"
    chown root:shell "$1"
    chmod -R 644 "$1"
    chmod 755 "$1"
    touch -t 197001010800 "$1"/*
    touch -t 197001010800 "$1"
    print_log "fix permissions: $?"
}

set_selinux_context(){
    [ "$(getenforce)" = "Enforcing" ] || return 0
    default_selinux_context=u:object_r:system_security_cacerts_file:s0
    selinux_context=$(ls -Zd $1 | awk '{print $1}')

    if [ -n "$selinux_context" ] && [ "$selinux_context" != "?" ]; then
        chcon -R $selinux_context $2
    else
        chcon -R $default_selinux_context $2
    fi
}

compatible(){
    # compatible adguard or other
    # Hash 47ec1af8 is for "AdGuard Intermediate CA" intermediate.
    print_log "Compatible adguard"
    cert_dir=$MODULE_CERT_DIR
    print_log "Running compatibility cleanup for potentially conflicting certificates."

    # Remove by filename pattern (hash: 47ec1af8.*)
    rm -f "$cert_dir"/47ec1af8.*
    print_log "Removed files matching '47ec1af8.*'."

    # Remove by content string "Guard Personal Intermediate"
    for cert_file in "$cert_dir"/*; do
        # Ensure it is a file before trying to read it
        if [ -f "$cert_file" ]; then
            # Use grep -q for a silent, efficient check
            if grep -q "Guard Personal Intermediate" "$cert_file"; then
                print_log "Removing file containing 'Guard Personal Intermediate': $(basename "$cert_file")"
                rm -f "$cert_file"
            fi
        fi
    done
    print_log "Compatibility cleanup status:$?"

    # Support OTG big version update
    # 遍历模块内所有带版本号的 conscrypt 目录，删除与当前系统版本不一致的旧目录，
    # 避免 find 顺序不确定导致取错目录、以及存在多个旧版本目录时只清理第一个
    for apex_dir in $MODDIR/apex/com.android.conscrypt@*; do
        [ -d "$apex_dir" ] || continue
        apex_num_name=$(basename "$apex_dir")
        if [ "$apex_num_name" != "$APEX_CONSCRYPT_NUM_NAME" ]; then
            rm -rf "$MODDIR/apex/$apex_num_name"
            print_log "Removed old conscrypt directory: $MODDIR/apex/$apex_num_name"
        fi
    done
    mkdir -p -m 755 "$MODULE_APEX_CONSCRYPT_NUM_DIR"
}

# ==================== nsenter 兼容层 ====================
# 模块必须在 init / zygote 的 mount namespace 里重复 bind 挂载，否则已经运行
# 起来的进程看不到新的证书目录。这里有两个坑：
#
# 1) nsenter 有两种写法：
#      util-linux: nsenter --mount=/proc/<pid>/ns/mnt -- CMD
#      toybox    : nsenter -t <pid> -m -- CMD     （Android 自带的就是 toybox）
# 2) 不同进程的 namespace 关系不一样：init 往往和我们同 ns（无需切换），
#    zygote / webview_zygote 一定不同 ns（必须切换）。
#
# 旧代码对所有 pid 都用第一种写法且不检查返回值，失败时静默跳过。
# 现在：先对"ns 确实不同的 pid"验证哪种写法有效（用 readlink 对比 ns 身份，
# 而不是看退出码），之后逐个 pid 走 ns_run()，同 ns 就直接执行。
NSENTER_TRY="path toybox"
NSENTER_STYLE=path

nsenter_probe() {
    _np_ref=""
    for _np_pid in 1 $(pgrep zygote64) $(pgrep zygote) $(pgrep webview_zygote); do
        _np_t=$(readlink /proc/$_np_pid/ns/mnt 2>/dev/null)
        _np_s=$(readlink /proc/self/ns/mnt 2>/dev/null)
        if [ -n "$_np_t" ] && [ "$_np_t" != "$_np_s" ]; then
            _np_ref=$_np_pid
            break
        fi
    done
    if [ -z "$_np_ref" ]; then
        print_log "nsenter: every visible process shares our mount namespace; order kept: $NSENTER_TRY"
        return 0
    fi
    _np_target=$(readlink /proc/$_np_ref/ns/mnt 2>/dev/null)
    if [ "$(nsenter --mount=/proc/$_np_ref/ns/mnt -- readlink /proc/self/ns/mnt 2>/dev/null)" = "$_np_target" ]; then
        NSENTER_TRY="path toybox"
    elif [ "$(nsenter -t "$_np_ref" -m -- readlink /proc/self/ns/mnt 2>/dev/null)" = "$_np_target" ]; then
        NSENTER_TRY="toybox path"
    else
        print_log "nsenter: neither syntax switched namespaces (reference pid $_np_ref)"
    fi
    NSENTER_STYLE=$(echo $NSENTER_TRY | cut -d' ' -f1)
    print_log "nsenter: reference pid=$_np_ref ($_np_target) order=$NSENTER_TRY"
}

# 在指定 pid 的 mount namespace 里执行命令；同 ns 时直接执行。
ns_run() {
    _nr_pid=$1
    shift
    _nr_t=$(readlink /proc/$_nr_pid/ns/mnt 2>/dev/null)
    _nr_s=$(readlink /proc/self/ns/mnt 2>/dev/null)
    if [ -n "$_nr_t" ] && [ "$_nr_t" = "$_nr_s" ]; then
        "$@"
        return $?
    fi
    for _nr_style in $NSENTER_TRY; do
        case "$_nr_style" in
            path)   nsenter --mount=/proc/$_nr_pid/ns/mnt -- "$@" ;;
            toybox) nsenter -t "$_nr_pid" -m -- "$@" ;;
        esac
        if [ $? -eq 0 ]; then
            NSENTER_STYLE=$_nr_style
            return 0
        fi
    done
    return 1
}

# 合并所有用户的 cacerts-added（含工作资料/多用户），不再只看 user 0
merge_user_certs() {
    for _ucd_dir in $USER_CERT_DIRS; do
        [ -d "$_ucd_dir" ] || continue
        cp -u "$_ucd_dir"/* "$MODULE_CERT_DIR" 2>/dev/null
        print_log "merged user certs from $_ucd_dir"
    done
}

# 挂载结果自检：生效目录里应能看到模块里的证书数量。
# 旧代码不做任何校验，"挂载成功但内容空/没生效"只能等用户反馈才发现。
verify_cert_mount() {
    _vc_target=$1
    _vc_want=$(ls -A "$MODULE_CERT_DIR" 2>/dev/null | wc -l)
    _vc_got=$(ls -A "$_vc_target" 2>/dev/null | wc -l)
    print_log "verify $_vc_target: module=$_vc_want effective=$_vc_got"
    if [ "$_vc_want" -gt 0 ] && [ "$_vc_got" -lt "$_vc_want" ]; then
        print_log "WARNING: $_vc_target shows fewer certificates than the module ($_vc_got < $_vc_want)"
        return 1
    fi
    return 0
}