# VPS Hardening Toolkit

[![Quality](https://github.com/allury/vps-init/actions/workflows/quality.yml/badge.svg)](https://github.com/allury/vps-init/actions/workflows/quality.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

面向 Debian 和 Ubuntu VPS 的交互式初始化与安全加固脚本。当前版本为 **1.2.3**，集中提供系统更新、系统清理、SWAP、时区、SSH、Fail2ban、BBR、DNS 和 IPv6 等常用运维操作。

> [!WARNING]
> 本项目会修改 SSH、网络、内核及系统服务配置。运行前请创建快照、确认云厂商控制台可用，并保留一个已登录的备用会话。请先在测试实例验证，再用于生产环境。

## 功能

- 独立的系统更新与分级清理
- SWAP 创建、检查与删除
- 时区配置与唯一时间同步服务检查
- SSH 端口及密钥登录加固
- Fail2ban 安装与规则配置
- BBR 与 FQ 队列配置
- DNS 同步兼容 systemd-resolved、Netplan 和已加载的 interfaces/cloud-init 配置
- IPv4/IPv6 优先级和 IPv6 开关
- SSH、Fail2ban、SWAP、DNS 和 IPv6 的配置校验与失败回滚
- Ubuntu 24.04+ `ssh.socket` 处理、真实监听端口检测和 Fail2ban 端口同步
- BBR、SSH、DNS、IPv6、SWAP 与 Fail2ban 关键状态汇总
- 旧内核安全保留清理，以及仅保留当前运行内核的高风险高级清理

## 支持范围

| 系统 | 版本 | 状态 |
| --- | --- | --- |
| Debian | 12 / 13 | 支持；Debian 12 已进入 LTS，软件包覆盖范围需单独核对 |
| Ubuntu | 20.04 | 支持；需有效的 Ubuntu Pro 合同并启用 ESM Infra |
| Ubuntu | 22.04 / 24.04 | 支持 |

脚本只接受上述版本对应的官方代号，并检查当前架构和维护阶段。Ubuntu 20.04 安装 Fail2ban 时还需启用 ESM Apps。其他发行版、容器内非 systemd 环境以及已经结束安全维护的系统不会自动放行。

脚本依赖 Bash、systemd 和 Debian 系软件包管理工具。GitHub Actions 会在 Debian 12、Debian 13、Ubuntu 20.04、Ubuntu 22.04 和 Ubuntu 24.04 官方容器中执行 Bash 语法、回归测试与内核元数据检查；涉及真实 systemd、SSH 和网络状态的写入仍应先在可恢复的 VPS 上验证。

## 快速开始

请先阅读脚本，再以 `root` 权限运行：

```bash
curl -fsSL https://raw.githubusercontent.com/allury/vps-init/main/vps.sh -o vps.sh
chmod +x vps.sh
sudo ./vps.sh
```

不建议直接使用 `curl | bash`，因为这会跳过运行前审查。

## 运行前检查

1. 为 VPS 创建可恢复的快照。
2. 确认能够通过云厂商控制台或救援模式登录。
3. 将 SSH 公钥写入 `/root/.ssh/authorized_keys`。
4. 修改 SSH 端口时，同步更新安全组和防火墙规则。
5. 在关闭当前 SSH 会话前，用新会话验证登录。
6. 保持官方软件源可用；复杂网络拓扑、NetworkManager 或旧版 Netplan 环境需要由管理员手动配置 DNS。

脚本日志默认写入 `/var/log/vps_init.log`，权限为 `0600`，并进行大小限制和敏感字段脱敏；不可写时会回退到随机命名的 `/tmp/vps_init-<UID>.*.log`。配置备份保存在 `/var/backups/vps-init/`。

## 开发与检查

```bash
bash -n vps.sh
for test_file in tests/test-*.sh; do bash "$test_file"; done
shellcheck --severity=error vps.sh tests/*.sh
```

提交代码前请阅读 [贡献指南](CONTRIBUTING.md)。安全问题请按 [安全策略](SECURITY.md) 私下报告，不要公开创建 Issue。

## 许可证

本项目采用 [MIT License](LICENSE)。
