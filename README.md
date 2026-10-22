# [MoveCertificate](https://github.com/ys1231/MoveCertificate)

[English](README.en.md) | [Türkçe](README.tr.md)

这是一个`Magisk/KernelSU/APatch`模块，用于将用户 CA 合并到系统证书库，支持 `Android 7-17`。
Android 14–17 可选择内置模式，KernelSU 需要能挂载 APEX 的元模块（例如 Mountify）；启动后会校验 init、Zygote 和 WebView 启动器中的证书内容。内置模式仅在 init 验证成功后补齐缺失的启动器命名空间挂载，失败时保留具体原因。兼容模式无需元模块。修复及验证范围见 [FIXES.md](FIXES.md)。
本仓库只维护 MoveCertificate 证书模块及 WebUI。
WebUI 可逐张选择用户证书是否迁移，取消挂载保留原证书、重启后生效；AdGuard 根证书默认开启，中间证书默认关闭。
如果手机是官方镜像,可能就需要借助模块,如果是自己编译的直接内置或者`remount`手动移一下就行了.

# 使用方法 

- 优先使用系统设置安装, 不需要处理编码问题

1. 导出证书后直接`push`到手机,使用系统设置正常安装证书,完了重启即可,不需要格式转换.
2. 可搭配 [appproxy](https://github.com/ys1231/appproxy) vpn代理工具.


## 手动安装证书到系统证书目录

- 推荐使用 Android 系统设置安装 CA。手动输入仅在设备具有 `openssl` 且验证通过时安装；没有解析器时保留输入并跳过。
- 正常情况下,不需要此场景.
- Reqable 直接导出的HASH.0 不一定能用, 建议导出crt, 使用系统设置正常安装或使用下面命令转换否则即使证书文件移动成功, 因为编码问题系统也无法识别

0. 如果证书已经移动过或者内置到源码中，会发现直接通过系统安装，实际证书并没有被安装进去，需要保留这种场景
1. 导出抓包软件证书 转换 证书为 pem 格式
2. 获取 der 证书 

```shell
# DER 用于证书指纹计算，模块新增的系统证书文件使用 PEM。
## 1. 计算 pem
openssl x509 -inform PEM -subject_hash_old -in cacert.pem
## 2. 转 der
openssl x509 -in cacert.pem -outform der -out cacert.der
### 2.1 或者 crt
openssl x509 -in cacert.crt -outform der -out cacert.der
mv cacert.der 02e06844.0

# der 证书 
## 1. 计算 der 
openssl x509 -in cacert.der -inform der -subject_hash_old -noout
## 2. 重命名证书为 hash值.0
mv cacert.der 02e06844.0
# 或者直接使用手机安装后,提取用户目录的证书出来,就不需要考虑计算和格式转换问题.
```

![20221109212126575](README.assets/20221109212126575.png)

3. 获取到 der 格式证书`02e06844.0`,或者共存`02e06844.1`
4. 先 `adb push 02e06844.0 /data/local/tmp/`，再以 root 将该文件移动到 `/data/local/tmp/cert/`（此目录仅 root 可写）。
5. 重启即可

## MoveCertificate web

- 这是一个 web 网页用于 MoveCertificate 模块显示已安装的证书列表。
- 同时也可以查看模块安装证书的详细信息。
- 以及长按可以删除已安装的证书。

# 打包命令
```shell
./buildzip.sh all
```
构建产物位于 `dist/MoveCertificate-v*.zip`。构建不会安装模块或重启手机。
安装后完整重启。若仍提示挂载验证失败，可通过 ADB 获取只读诊断：

```sh
adb shell su -c 'sh /data/adb/modules/MoveCertificate/sh/diagnose.sh'
adb pull /data/local/tmp/MoveCertificate.log
```

诊断输出包含进程名称、命名空间和具体缺失/不一致的证书文件名，不输出证书内容。
# 使用实测
![2024-02-19_01.27.27](README.assets/2024-02-19_01.27.27.png)

## Star History

[![Star History Chart](https://star-history.dera.page/svg?repos=ys1231/MoveCertificate&type=Date)](https://star-history.dera.page/#ys1231/MoveCertificate&Date)

# 参考链接:
- http://www.zhuoyue360.com/crack/60.html
- https://topjohnwu.github.io/Magisk/guides.html#boot-scripts
- https://github.com/Magisk-Modules-Repo/movecert
- https://github.com/andyacer/movecert
- https://book.hacktricks.xyz/v/cn/mobile-pentesting/android-app-pentesting/install-burp-certificate#android-14-zhi-hou 
- https://kernelsu.org/zh_CN/guide/module.html
