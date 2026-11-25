# 雷神加速器：关机自动暂停时长

关机瞬间由计划任务调用雷神云端接口暂停时长计费，无需常驻进程，也不依赖客户端响应。

## 需关闭开机自动启动雷神加速器，否则无法生效

## 文件

| 文件 | 作用 |
| --- | --- |
| leigod-pause.ps1 | 核心：自动定位客户端日志目录 → 读 account_token → 调 pause / info / recover |
| install-shutdown-task.ps1 | 安装：复制核心脚本到 C:\ProgramData\LeigodGuard，注册关机触发任务 |
| install-shutdown.cmd | 双击安装入口 |
| uninstall-shutdown-task.ps1 | 卸载：删除关机任务和 C:\ProgramData\LeigodGuard |
| uninstall-shutdown.cmd | 双击卸载入口 |
| pause-now.cmd | 立即手动暂停计时（等价于关机时的动作） |
| README.md | 本说明 |

## 安装

双击 install-shutdown.cmd（弹 UAC，需要管理员一次）：

1. 把 leigod-pause.ps1 复制到 C:\ProgramData\LeigodGuard\
2. 探测一次客户端日志目录，固定到 leigod-pause.ini
3. 注册计划任务 LeigodPauseOnShutdown，以 SYSTEM 运行，触发事件：
   - System 日志 User32 / 1074（用户发起关机或重启）
   - System 日志 Kernel-General / 13（系统正在关闭）

## 验证

关机或重启后执行：

    Get-ScheduledTaskInfo -TaskName LeigodPauseOnShutdown

LastRunTime 应为刚才关机的时间，LastTaskResult 应为 0。
日志在 C:\ProgramData\LeigodGuard\leigod-pause.log，末尾应有 OK - billing paused。

手动测试（会立即暂停计时）：

    pause-now.cmd

恢复计时（客户端里点恢复即可，或）：

    powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\LeigodGuard\leigod-pause.ps1 -Recover

## 卸载

双击 uninstall-shutdown.cmd：删除 LeigodPauseOnShutdown 与 C:\ProgramData\LeigodGuard。


## 原理与注意

- 接口：POST https://webapi.leigod.com/api/user/pause（备用 webapi.nn.com），
  body {"account_token":"<token>"}；code 0 成功、400803 已暂停（视为成功）、400007 登录态过期。
- token 来源：客户端 HTTP 日志里的 account_token=...（自动取最新）。日志目录自动定位：
  leigod-pause.ini 的 log_dir → 运行中的 leigod.exe → 注册表卸载项 → Preferences →
  快捷方式 → 各盘常见目录穷举。日志会打印 [pause] log dir: ...
- 假暂停：PC 端恢复加速不会清除云端暂停标记，所以每次关机都无条件调 pause，
  已暂停返回 400803，幂等无害。
- token 有效期约 7 天；过期后重新登录雷神客户端，脚本自动读到新 token。
- 本机是 Windows 家庭中文版，没有 gpedit.msc，计划任务是等价做法。

