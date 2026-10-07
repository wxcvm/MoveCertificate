##########################################################################################
#
# Magisk Module Installer Script
#
##########################################################################################

# skip all default installation steps
SKIPUNZIP=0

# Set what you want to display when installing your module

print_modname() {
  ui_print " "
  ui_print "*******************************"
  ui_print " Supports Android7-17 move cert"
  ui_print "*******************************"
  ui_print " "
}

# Copy/extract your module files into $MODDIR in on_install.

on_install() {

  F_TARGETDIR="$MODPATH/system/etc/security/cacerts/"
  D_CERTIFICATE="$MODPATH/certificates"
  APEX_CONSCRYPT_DIR="$MODPATH/apex/com.android.conscrypt/cacerts"

  # mkdir -p "$F_TARGETDIR"
  # create temp cert
  D_TMP_CERT=/data/local/tmp/cert

  if [ -f "$D_TMP_CERT" ]; then
    ui_print "- ${D_TMP_CERT} found"
  else
    # 该目录曾经以 0777 创建：任何应用都能往里投一张证书，而 post-fs-data 会把
    # 它装进系统信任库 —— 等于一条提权路径。现在是仅 root 可访问；若目录已存在
    # （旧版本创建过）也顺手收紧权限。
    if [ -d "$D_TMP_CERT" ]; then
      chmod 700 "$D_TMP_CERT" 2>/dev/null
    else
      mkdir -p -m 700 "$D_TMP_CERT"
    fi
  fi
  # ui_print "- mkdir $MODPATH/certificates"
  # ui_print "- mkdir $F_TARGETDIR"
  mkdir -p -m 755 "$F_TARGETDIR"
  mkdir -p -m 755 "$APEX_CONSCRYPT_DIR"
  mkdir -p -m 755 "$D_CERTIFICATE"
  mkdir -p -m 755 /data/misc/user/0/cacerts-added

  APEX_VER_NAME=$(basename "$(find /apex -type d -name 'com.android.conscrypt@*' 2>/dev/null | head -n1)")
  if [ -n "$APEX_VER_NAME" ]; then
    mkdir -p -m 755 "$MODPATH/apex/$APEX_VER_NAME/cacerts"
    # ui_print "- Created versioned apex dir: $APEX_VER_NAME"
  fi

  # Create default mode config
  MODE_CONF="$MODPATH/mode.conf"
  if [ ! -f "$MODE_CONF" ]; then
    echo "mode=compatible" > "$MODE_CONF"
    ui_print "- Created default mode.conf (compatible mode)"
  fi

  # Preserve learned certificate names across upgrades
  # (the packaged cert_names.json only carries the built-in seed names)
  OLD_CERT_NAMES="/data/adb/modules/MoveCertificate/cert_names.json"
  if [ -f "$OLD_CERT_NAMES" ]; then
    cp "$OLD_CERT_NAMES" "$MODPATH/cert_names.json"
    ui_print "- Preserved existing cert_names.json"
  fi
}

# You can add more functions to assist your custom script code
print_modname
on_install
