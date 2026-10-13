#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
stage="$root/.cache/panvk-present-probe"
sdk="${ANDROID_HOME:?Android SDK required}"
bt="$sdk/build-tools/35.0.0"
ndk="$sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64"
upstream=fd6ed91eff1c8d3a83307a2348b959bb93797011
base="https://raw.githubusercontent.com/zenithblue-oss/panvk-kbase-android/$upstream"
mkdir -p "$stage/src" "$stage/lib/arm64-v8a" "$stage/classes" "$stage/dex" "$stage/assets"
cd "$stage"
curl --fail --location --retry 3 "$base/apps/panvk-test/app/src/main/cpp/swapchain.c" -o src/swapchain.c
curl --fail --location --retry 3 "$base/tests/dxvk/vulkan/clip-cull/clip_cull_spv.h" -o src/clip_cull_spv.h
curl --fail --location --retry 3 "$base/LICENSES/MIT.txt" -o assets/upstream-MIT.txt
printf '%s\n' \
  'cd3699ac26546292aa27662b58212aee2a0ed63c63daf52ae3ea555c33e67723  src/swapchain.c' \
  '1941aaf3f57d1e403ef131917623371530407c36347cc7f201cf91014790084e  src/clip_cull_spv.h' \
  'da0d33f62b0064974023a941540c0474426b3fbd6245adf13694be1b88c8533f  assets/upstream-MIT.txt' | sha256sum -c -
python3 "$root/driver-fix/probe/prepare-source.py" src/swapchain.c
# Reuse the already built driver, checking its exact bytes before packaging.
gh run download 38381304473 -R wxcvm/MoveCertificate -n PanVK-RC3-anbfix3-experimental -D driver
driver=$(find driver -name libvulkan_panfrost.so -print)
test -f "$driver"
printf '4f91569f9be0bb3a148ac1ee7c03dbfc77e8b5e36fa5d2a97a8c16b696b39345  %s\n' "$driver" | sha256sum -c -
cp "$driver" lib/arm64-v8a/libvulkan_panfrost.so
cp -R "$root/driver-fix/licenses" assets/driver-licenses
cp "$(dirname "$driver")/SOURCE.json" assets/driver-source.json
cp "$(dirname "$driver")"/libdrm-*-source.tar.xz assets/
"$ndk/bin/aarch64-linux-android35-clang" -std=c11 -O2 -g -shared -fPIC \
    src/swapchain.c -o lib/arm64-v8a/libpresentprobe.so -landroid -llog -ldl -lm
"$bt/aapt2" link -I "$sdk/platforms/android-35/android.jar" \
    --manifest "$root/driver-fix/probe/AndroidManifest.xml" -A assets -o base.apk
javac -source 8 -target 8 -cp "$sdk/platforms/android-35/android.jar" \
    -d classes "$root/driver-fix/probe/MainActivity.java" "$root/driver-fix/probe/Native.java"
mapfile -t classes < <(find classes -name '*.class')
"$bt/d8" --min-api 35 --lib "$sdk/platforms/android-35/android.jar" --output dex "${classes[@]}"
cp dex/classes.dex .
zip -q base.apk classes.dex lib/arm64-v8a/*.so
"$bt/zipalign" -p -f 4 base.apk aligned.apk
# Disposable diagnostic signing key, unrelated to user/release signing keys.
keytool -genkeypair -keystore debug.jks -storepass android -keypass android \
    -alias debug -dname 'CN=MoveCertificate Diagnostic' -keyalg RSA -keysize 2048 -validity 30
"$bt/apksigner" sign --ks debug.jks --ks-pass pass:android --out PanVK-Display-Probe.apk aligned.apk
"$bt/apksigner" verify --verbose PanVK-Display-Probe.apk
sha256sum PanVK-Display-Probe.apk > SHA256SUMS
