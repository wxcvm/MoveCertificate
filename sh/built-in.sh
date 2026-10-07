#!/system/bin/sh
MODDIR=${0%/*}

# 使用内置方法

init_low_builtin_method() {

    print_log "Use built-in method"
    rm -rf $MODULE_CERT_DIR/*
    print_log "Backup user certs ($USER_CERT_DIRS)"
    merge_user_certs
    move_custom_cert
    compatible
    cp -f $MODULE_CERT_DIR/* $MODULE_SYSTEM_CERT_DIR
    print_log "Install $MODULE_SYSTEM_CERT_DIR status:$?"
    fix_system_permissions $MODULE_SYSTEM_CERT_DIR
    print_log "Fix $MODULE_SYSTEM_CERT_DIR permissions status:$?" 
    set_selinux_context $SYSTEM_CERT_DIR $MODULE_SYSTEM_CERT_DIR
    
    return 0
}

init_high_builtin_method() {
    
    print_log "Use built-in method"
    rm -rf $MODULE_CERT_DIR/*
    print_log "Backup user certs ($USER_CERT_DIRS)"
    merge_user_certs
    move_custom_cert
    compatible
    cp -f $MODULE_CERT_DIR/* $MODULE_APEX_CONSCRYPT_DIR
    print_log "Install $MODULE_APEX_CONSCRYPT_DIR status:$?"
    rm -rf $MODULE_APEX_CONSCRYPT_NUM_DIR/*
    cp -f $MODULE_CERT_DIR/* $MODULE_APEX_CONSCRYPT_NUM_DIR
    print_log "Install $MODULE_APEX_CONSCRYPT_NUM_DIR status:$?"
    fix_system_permissions14 $MODULE_APEX_CONSCRYPT_DIR
    print_log "Fix $MODULE_APEX_CONSCRYPT_DIR permissions status:$?" 
    fix_system_permissions14 $MODULE_APEX_CONSCRYPT_NUM_DIR
    print_log "Fix $MODULE_APEX_CONSCRYPT_NUM_DIR permissions status:$?" 
    set_selinux_context $APEX_CONSCRYPT_DIR $MODULE_APEX_CONSCRYPT_DIR
    set_selinux_context $APEX_CONSCRYPT_DIR $MODULE_APEX_CONSCRYPT_NUM_DIR
    
    return 0
}
