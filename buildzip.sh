#!/bin/bash
# 行尾必须是 LF（见 .gitattributes）：CRLF 会让 shebang 变成 "#!...\r"，
# 在 Linux / mksh 下报 "cannot execute: required file not found"。

# 检查参数
BUILD_WEB=true
AUTO_UPDATE=false
if [ "$1" == "sweb" ]; then
    BUILD_WEB=false
fi

if [ "$1" == "auto" ]; then
    AUTO_UPDATE=true
fi

if [ "$1" == "all" ]; then
    BUILD_WEB=true
    AUTO_UPDATE=true
fi

# 从 update.json 动态提取版本号
VERSION=$(grep -o '"version": *"[^"]*"' update.json | sed 's/"version": *"\([^"]*\)"/\1/')

# 生成zip文件名
ZIP_FILE="MoveCertificate-${VERSION}.zip"

echo "正在打包: ${ZIP_FILE}"

# 删除旧的zip文件（如果存在）
if [ -f "$ZIP_FILE" ]; then
    echo "删除旧文件: ${ZIP_FILE}"
    rm "$ZIP_FILE"
fi

# 编译 webroot（当参数为 sweb 时跳过）
if [ "$BUILD_WEB" = true ]; then
    echo "正在编译 webroot..."
    # --ignore-scripts：不执行依赖包的生命周期脚本（供应链攻击最常见的入口，
    # SonarCloud shell:S6505）。这里安全：esbuild 0.16+ 的平台二进制来自
    # optionalDependencies（@esbuild/<platform>），不依赖 postinstall；
    # typescript / javascript-obfuscator 都是纯 JS。
    cd webdev && npm install --ignore-scripts && npm run build && cd ..
else
    echo "跳过 webroot 编译..."
fi

# 压缩文件和目录
zip -r "$ZIP_FILE" \
    META-INF \
    webroot \
    sh \
    *.sh \
    LICENSE \
    *.md \
    module.prop \
    system.prop \
    update.json \
    cert_names.json \
    README.assets \
    -x "buildzip.sh"

echo "打包完成: ${ZIP_FILE}"

if [ "$AUTO_UPDATE" = true ]; then
    echo "push and install"
    adb push "$ZIP_FILE" /sdcard/Download/
    adb shell ksud module install /sdcard/Download/"$ZIP_FILE" || true
    adb shell "su -c apd module install /sdcard/Download/$ZIP_FILE" || true
    adb reboot
else
    echo "跳过 安装更新..."
fi
