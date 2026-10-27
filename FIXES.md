# v1.6.8 修复与验证

正式版新增：两种模式都先校验当前证书库，已正确挂载时不调用挂载脚本。内容确实
不符才修复，子命名空间使用已验证的 init 库，避免兼容模式依赖隐藏的模块目录。
同一命名空间内、相同目录身份的活动 APEX 别名只计算一次内容校验，不跨进程缓存。
进程名称读取 cmdline，避免 Zygote 仅显示成 main；只读诊断也按命名空间去重。

WebUI 混淆使用固定种子，脚本文件名按最终发布字节生成内容哈希。打包只收集明确列出
的文档图片，并检查更新元数据版本与模块版本一致。Release 绑定经过测试的标签提交，
附带 SHA-256 文件，拒绝覆盖已有发布附件。

2026-10-27，PGKM10 / Android 17 / KernelSU：当前安装的 v1.6.7 已以兼容模式完成启动，
运行状态 ready。v1.6.8 校验器只读检查 init、32/64 位 Zygote、WebView、Quetta 启动器
五个命名空间均通过。Android 原生 mksh 下通过运行时、命名空间、启动状态及真实
flock 回归；在独立且递归私有的挂载命名空间中，实际执行两种模式的 bind 修复，
验证目标内容、原始输入保留及无效源拒绝。未修改当前模式或原证书选择。
这不等于 v1.6.8 完整开机验收，内置模式的元模块开机路径仍待完整重启验证。

本仓库仅维护证书模块和 WebUI。安装包使用明确的运行时文件清单，只输出到 dist/；
本地诊断、额外脚本、测试证书和旧安装包不能混入产物。构建不再自动安装或重启。

针对“init 验证成功、部分 Zygote/WebView 命名空间失败”的启动日志：校验改为将
准备好的文件 SHA-256 清单及独立 Shell 代码传入目标命名空间，不在目标视图重新加载
模块目录、配置或证书缓存。日志记录 PID、进程名、命名空间、退出状态及缺失/不符的
文件名，区分内容失败和 namespace 进入失败。

内置模式中，必须先验证 init 的完整预期内容；只有目标命名空间确实缺少目录、证书
或内容不符时，才使用 /proc/1/root 下已经验证的活动证书库补挂载。再次检查源、目标
命名空间身份和活动 APEX 别名，校验失败撤销本轮新绑定，保留 builtin 配置。不能进入
命名空间、init 内容错误或补挂载失败仍报告失败，不将所有错误一律当作挂载缺失。
启动器退出时最多重新获取进程列表三次；post-mount 的早期失败可在开机后重试，证书
准备失败不能用旧缓存恢复成“成功”。

v1.6.7 的原始失败日志未保留进程名称，不能从历史 PID 推断当时失败的具体进程。
上述开机逻辑包含隔离回归，完整启动结果需以对应版本的设备启动日志为准。

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

验证命令（Node 24；Linux/Android shell）：

```sh
cd webdev
npm ci --ignore-scripts
npm run typecheck
cd ..
node --test tests/*.test.mjs
sh tests/runtime-test.sh
sh tests/namespace-test.sh
sh tests/service-test.sh
sh tests/lock-test.sh
python3 -m unittest discover -s tests -p '*_test.py'
cd webdev
npm run build
cd ..
python3 scripts/package.py
```

测试只操作临时夹具，模拟所有挂载操作；锁测试使用真实 flock；测试 CA 不进入安装包。
Actions 输出证书模块安装包。下载 Actions artifact 后需先解压外层 artifact ZIP，再用
Root 管理器安装其中的模块 ZIP。main 的自动更新信息仅在正式附件发布并核验后推进，
避免指向尚不存在的安装包。
