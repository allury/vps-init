# vps-init

面向 Debian VPS 的交互式初始化、安全加固与日常维护脚本。当前版本为 **2.0.0**。

项目遵循以下原则：

> Debian-only、保守修改、明确验证、失败回滚、日志可诊断。

## 支持范围

| 系统 | 代号 | 架构 |
| --- | --- | --- |
| Debian 12 | Bookworm | amd64、arm64 |
| Debian 13 | Trixie | amd64、arm64 |

脚本会核对 `/etc/os-release` 中的版本与代号、`dpkg` 架构、systemd 运行环境和系统维护阶段。范围外系统会直接停止，不尝试兼容。

## 主要功能

- 系统维护：APT 更新检查、常规升级、完整升级、Debian 官方内核更新
- 系统清理：APT 缓存、无用依赖、残留配置、旧内核和 systemd 日志
- SWAP：查看状态、创建 1G/2G/自定义 swapfile、设置 `vm.swappiness`、删除脚本托管的 `/swapfile`
- 时间：设置 `Asia/Shanghai` 并检查可用的 systemd 时间同步服务
- SSH：查看或修改端口、检查 root 密钥登录、禁用密码和键盘交互登录
- Fail2ban：在现有 `jail.local` 中增量维护 `sshd` jail，并验证运行参数与端口
- BBR：仅配置 `fq` 与 `bbr`，不写入额外 TCP 调优参数
- DNS：支持 systemd-resolved、ifupdown 和静态 `/etc/resolv.conf`
- IPv6：查看、启用、禁用及设置 IPv4 地址选择优先级
- 诊断：关键状态汇总、只读配置检查和最近运行日志

## 安全边界

涉及系统状态的操作按 `PRECHECK → BACKUP → APPLY → VERIFY → ROLLBACK` 组织。脚本不会自动接管无法可靠判断所有权的配置。

- APT 软件包来源通过 Debian Release 元数据中的 Origin、Suite、Codename 和 component 校验，不限制官方镜像站域名
- 拒绝 testing、unstable、sid 和 Bookworm/Trixie 跨版本混源进入自动安装或升级流程
- SSH 修改后检查 `sshd -t`、最终有效配置、`ssh.service`、监听端口及本机 SSH 协议握手
- Fail2ban 重启后最多等待 15 秒就绪，并验证 sshd jail、封禁参数和实际端口
- SWAP 创建按文件系统处理 ext4、XFS 和 Btrfs，每个阶段独立检查并在失败时回滚
- IPv6 SSH 会话中禁止直接关闭 IPv6
- NetworkManager、未知解析器所有权、多出口或复杂网络拓扑下不自动修改 DNS
- 旧内核清理始终保护当前运行内核，并在执行前展示 APT 删除预览
- 单实例锁使用 `flock`；进程正常退出、信号退出或异常终止后锁都会由内核释放

高风险操作前仍建议创建云平台快照，并确认控制台或救援模式可用。

## 使用方法

```bash
curl -fsSLo vps.sh https://raw.githubusercontent.com/allury/vps-init/main/vps.sh
chmod +x vps.sh
sudo ./vps.sh
```

运行前可先检查下载内容：

```bash
sed -n '1,220p' vps.sh
```

## 日志

日志默认写入：

```text
/var/log/vps_init.log
```

文件权限为 `600`，超过 1 MiB 时自动保留最近 1000 行。DETAIL 日志记录模块、阶段、退出码和必要的截断输出，不记录密码、Token 或密钥内容。

查看最近日志：

```bash
sudo tail -n 100 /var/log/vps_init.log
```

## 从 1.2.x 升级

2.0.0 只支持 Debian 12/13 amd64/arm64。原有 Debian 配置会继续按配置所有权和加载顺序检测；脚本不会主动删除旧版本遗留文件。若检测到无法证明安全的旧配置、复杂 DNS 所有权或冲突的 sysctl 定义，会停止并给出日志提示。

## 质量检查

GitHub Actions 在 Debian 12 与 Debian 13 官方容器中执行：

- `bash -n`
- ShellCheck error 级别检查
- 全部离线回归测试
- SWAP、Fail2ban、SSH、BBR/sysctl、APT、内核清理、DNS、日志与安全边界测试

## License

[MIT](LICENSE)
