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

`driver-fix/` 提供原厂回退包和包含官方 PanVK RC3 的新驱动包，参见该目录说明。
新包保留经过 SHA-256、BuildID、HAL/ICD 导出、依赖和最低 API 35 校验的 RC3 原始库，
默认关闭全局替换，OpenGL/EGL 及 Vulkan 使用原厂。2026-10-12 在 PGKM10/G610 MC6 /
Android 17 实测，星穹铁道两次崩溃于 ColorX 的 `constructFragmentShadingRatesInfo`，
PC 为 0；恢复原厂 Vulkan 后用户确认可以进入游戏。这个平台的全局替换已明确阻止。
浏览器部分花屏由用户报告，尚未单独定位，不能把回退当作 PanVK 内部缺陷修复。
RC3 仍可作为支持自选驱动的应用的输入，具体应用需单独验证。

进一步的可撤销实机测试没有解决全局兼容：屏蔽整个 64 位 Vulkan 增强库、以及只让
`isColorxExcludedProcess` 返回 true 的精确绕过，两种方案均消除了原来的 ColorX
空函数调用，但仍崩溃于系统 `libvulkan.so + 0x35d48`。反汇编该位置为
`GetSwapchainImagesKHR` 路径解引用传入的 swapchain；寄存器 x1 为 0，说明交换链
为空。精确绕过时增强库仍在进程映射中；用户先报告能进入且画面正常，随后闪退，
所以短暂显示不能算运行验证通过。交换链创建失败的具体原因仍需独立定位。
测试库、游戏日志和私有 OEM 库未提交或打包；所有临时挂载已撤销，开机配置保持原厂。

后续独立探针确认 RC3 可以初始化 G610 MC6，报告 API 1.4.363；系统 native-buffer
内存导入仍误用句柄的第 0 个 `gralloc_extra` FD，真正的 DMA-BUF 在第 1 个。
同一缓冲区的 AHB 路径成功创建图像、导入并绑定内存。已准备遍历并验证 FD 的源码
补丁，helper 在本机通过真实导入、元数据拒绝和变化索引测试。RC3-anbfix1 已完整
重建，实机 native-buffer 与 AHB 路径均通过 GPU 清屏回读，4096 像素全部正确，
64 次导入销毁后 FD 数量不变。游戏实际加载 PanVK 后仍卡住或黑屏，进一步复现了
kbase 错用 DRM 同步复制的错误；RC3-anbfix2 已通过 64 次实机同步导出测试。
加入同步导入后发现每轮泄漏一个 FD，RC3-anbfix3 进一步修复 waiter 生命周期；
完整构建及实机回归通过，64 次同步往返 FD 数量保持 23 → 23，像素回读正常。
第三版的星穹铁道实测确认实际使用新版 Vulkan，用户反馈能进入、有画面，但仍有
闪烁、重影或错位。游戏及 Quetta 的全流程兼容仍未通过。
详见 [驱动检查记录](driver-fix/INVESTIGATION.md)。

验证命令（Node 24；Linux/Android shell）：

```sh
cd webdev
npm ci --ignore-scripts
npm run typecheck
cd ..
node --test tests/*.test.mjs
sh tests/runtime-test.sh
sh tests/lock-test.sh
sh tests/driver-test.sh
cd webdev
npm run build
cd ..
python3 scripts/package.py
```

测试只操作临时夹具，模拟所有挂载操作；锁测试使用真实 flock；测试 CA 不进入安装包。
Actions 输出三个独立安装包。下载 Actions artifact 后需先解压外层 artifact ZIP，再用
Root 管理器安装其中的模块 ZIP。`update.json` 仍指向现有正式发布，避免未发布版本触发
自动更新；v1.6.6 完成实机验证并发布 Release 后再更新此文件。
