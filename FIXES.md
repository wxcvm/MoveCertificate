# v1.6.6 修复与验证

Android 14–17 可以选择内置模式；删除此前仅依据 SDK 禁用或自动回退的判断。
KernelSU 的内置挂载由元模块提供，且提供者必须支持 APEX。实机 Mountify 2.0.4 的
`metamount.sh` 支持 APEX，但只收集模块的 `system/` 子目录；原来的模块根目录
`apex/` 不会被收集。现在同时输出 `system/apex/com.android.conscrypt/cacerts` 和
`apex/com.android.conscrypt/cacerts`，以及与活动目录身份相同的版本别名。
重建时清理旧证书和空的旧 APEX 别名目录，避免 OTA 后继续覆盖失效目录。
Android SDK 34/37 的隔离回归验证完整原生字节、用户证书、活动别名、OTA 清理以及
缺少用户证书时不能报成功。元模块完整开机挂载仍需设备重启验证。

实机复现了 Android mksh 没有向 BusyBox 传递锁描述符的问题，`flock` 报
`Bad file descriptor` 导致 WebUI 无法保存选择。显式 `9>&9` 传递同一打开文件描述后，
锁在父 shell 中持续有效；真实双进程测试验证互斥及退出释放。修复适用于证书选择、
模式切换、删除及启动脚本共用的状态锁。保存失败现在显示实际错误信息。
证书完整名称换行显示，并将状态和操作分行；不再依赖无法在手机上阅读的悬浮提示。
AdGuard 中间证书默认排除使用扩展正则，兼容 Android grep；根证书默认仍启用。

证书模块每次启动从当前原生系统库重新构建，保留原生文件原始字节；不再从旧缓存补回
已经删除的用户证书。所有用户输入按规范 DER 的 SHA-256 去重，同 subject hash 的不同
证书分配下一个 `.N`，新增输出统一使用 PEM，避免部分读取器不能读取 DER。
准备失败不会发布残缺证书集；空原生库、文件复制失败和挂载失败均报错。

兼容模式对 init 和 Zygote 的挂载命名空间分别验证完整证书内容，校验 namespace 切换实际
成功，并避免重复堆叠 bind mount。KernelSU/APatch 的 post-mount 阶段和开机完成后复查。
内置模式交由模块框架或元模块挂载后验证；保留用户配置，不按 Android 版本强制改变模式。
标准 AOSP 的新系统证书入口是 `/apex/com.android.conscrypt/cacerts`，参考
[Conscrypt 源码](https://android.googlesource.com/platform/external/conscrypt/+/refs/heads/main/platform/src/main/java/org/conscrypt/TrustedCertificateStore.java)。
不会向尚未确认是活动证书库的任意 apexdata 目录写入证书。

WebUI 显示本次 boot ID 对应的实际模式、验证状态和证书来源，按内容比较结果显示状态，
区分排除、未验证、失败、来源删除等情况。删除基于指纹及来源记录，仅删除仍匹配的
原输入；原生 CA 和当前活动挂载在重启前保持完整。Shell 非零退出状态会作为操作失败
显示。证书名称缓存改用指纹，避免不同证书共享 subject hash 时名称串用。

每张已验证的用户/自定义证书均可在 WebUI 勾选是否挂载。选择按指纹保存，作用于所有
相同证书的用户副本，并跨模块升级保留。取消只跳过迁移，不删除原证书；变更在完整
重启后生效，界面分别显示当前挂载结果和“待重启”的选择。AdGuard 根证书默认挂载，
个人中间证书维持原有默认不挂载行为，但用户可显式开启。原生系统 CA 始终保留。

推荐通过 Android 系统设置安装 CA，再重启。`/data/local/tmp/cert` 的任意文件只有在设备
具备 `openssl` 且通过 X.509/CA 验证时才会加入；无解析器时保留输入并记为未验证。
不会再依据首字节判断任意文件有效，也不会改变 Android 管理的用户证书目录权限。

PanVK 驱动子工程（`driver-fix/`、`scripts/build-panvk-*`、`scripts/prepare-driver.py`、
`scripts/package-wsi3.py`、驱动测试与 4 个 `panvk-*` workflow）已迁移到独立仓库
[wxcvm/panvk-pgkm10](https://github.com/wxcvm/panvk-pgkm10)，提交历史通过 `git subtree split`
完整保留。本仓库不再包含驱动源码、补丁、构建或打包流程。
（原驱动的设备验证记录见 panvk-pgkm10 的 INVESTIGATION.md；本仓库不再保留该文件。）

验证命令（Node 24；Linux/Android shell）：

```sh
cd webdev
npm ci --ignore-scripts
npm run typecheck
cd ..
node --test tests/*.test.mjs
sh tests/runtime-test.sh
sh tests/lock-test.sh
cd webdev
npm run build
cd ..
python3 scripts/package.py
```

测试只操作临时夹具，模拟所有挂载操作；锁测试使用真实 flock；测试 CA 不进入安装包。
Actions 输出证书模块安装包。下载 Actions artifact 后需先解压外层 artifact ZIP，再用
Root 管理器安装其中的模块 ZIP。`update.json` 仍指向现有正式发布，避免未发布版本触发
自动更新；v1.6.6 完成实机验证并发布 Release 后再更新此文件。
