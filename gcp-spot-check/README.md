# GCP Spot Instance 保活服务

<div align="center">

![Version](https://img.shields.io/badge/version-1.0.0-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Platform](https://img.shields.io/badge/platform-Linux-lightgrey)
![Shell](https://img.shields.io/badge/shell-bash-orange)

**自动监控和维护 Google Cloud Platform Spot 实例运行状态的智能工具**

[功能特性](## ✨ 功能特性) • [快速开始](#快速开始) • [使用指南](#使用指南) • [系统要求](#系统要求) • [常见问题](#常见问题)

</div>

---

## 📋 简介

GCP Spot Instance 保活服务是一个专为 Google Cloud Platform Spot 实例设计的自动化运维工具。它能够自动监控 Spot 实例的运行状态，并在实例被抢占或停止时自动重启，确保您的服务持续可用。

### 为什么需要这个工具？

- **Spot 实例价格优惠**：相比按需实例可节省高达 91% 的成本
- **自动恢复服务**：实例被抢占后自动重启，无需人工干预
- **多账号管理**：支持同时管理多个 GCP 账号下的所有实例
- **智能发现**：自动扫描并导入账号下的所有实例

## ✨ 功能特性

### 核心功能
- 🔄 **自动监控**：定时检查实例状态，支持自定义检查间隔
- 🚀 **自动重启**：检测到实例停止时立即发送启动命令
- 🌐 **多账号支持**：同时管理多个 GCP 账号和项目
- 🔍 **自动发现**：一键扫描并导入账号下的所有实例
- 📊 **统计分析**：实时查看监控统计和运行状态
- 📝 **完整日志**：详细记录所有操作和状态变化

### 技术特点
- **零依赖安装**：自动检测并安装所需组件
- **智能路径适配**：自动选择可用的日志存储路径
- **安全配置管理**：加密存储服务账号密钥
- **灵活的检查策略**：支持分钟级和小时级检查间隔
- **即时生效**：添加监控后立即执行首次检查

## 🚀 快速开始

### 一键安装

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/crazy0x70/scripts/refs/heads/main/gcp-spot-check/gcp-spot-check.sh)" @ install
```

### 使用命令

安装完成后，使用以下命令启动管理界面：

```bash
sudo gcpsc
```

### 一键卸载

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/crazy0x70/scripts/refs/heads/main/gcp-spot-check/gcp-spot-check.sh)" @ remove
```

## 📖 使用指南

### 1. 添加 GCP 账号

启动 `gcpsc` 后，选择 "账号管理" → "添加新账号"，支持三种认证方式：

#### 方式一：服务账号（推荐）
```
1. 准备服务账号 JSON 密钥文件
2. 选择 "使用服务账号 JSON 密钥文件"
3. 输入密钥文件路径
4. 选择是否自动发现实例
```

#### 方式二：粘贴密钥内容
```
1. 选择 "粘贴 JSON 密钥内容"
2. 粘贴完整的 JSON 内容
3. 按 Ctrl+D 结束输入
```

#### 方式三：个人账号
```
1. 选择 "使用个人 Google 账号登录"
2. 复制显示的 URL 到浏览器
3. 登录并授权
4. 将授权码粘贴回终端
```

### 2. 自动发现实例

添加账号后，系统会询问是否自动发现该账号下的所有实例：

```bash
是否自动发现并导入该账号下的所有实例？[y/N]: y
请输入默认检查间隔（分钟，默认10）: 10
```

系统将自动：
- 扫描所有可访问的项目
- 发现所有计算实例
- 导入实例并设置监控
- 立即执行首次状态检查

### 3. 管理监控实例

在账号管理界面，可以：

- **查看实例列表**：显示所有监控的实例及其检查间隔
- **修改检查间隔**：单独或批量修改实例的检查频率
- **立即检查**：手动触发指定实例的状态检查
- **删除监控**：移除不需要监控的实例
- **查看详情**：显示实例的完整信息和最后检查时间

### 4. 查看运行状态

主菜单提供多种状态查看选项：

- **监控统计**：查看账号、项目、实例的总体统计
- **运行日志**：查看最近的操作日志和状态变化
- **手动检查**：立即执行一次全量状态检查

## 🔧 配置说明

### 检查间隔设置

- **1-60 分钟**：按分钟级别检查
- **大于 60 分钟**：自动转换为小时级别（如 120 分钟 = 每 2 小时）
- **默认值**：10 分钟

### 文件位置

| 文件类型 | 路径 |
|---------|------|
| 主程序 | `/usr/local/bin/gcpsc` |
| 配置文件 | `/etc/gcpsc/config.json` |
| 服务账号密钥 | `/etc/gcpsc/keys/` |
| 检查时间记录 | `/etc/gcpsc/lastcheck/` |
| 运行日志 | `/var/log/gcpsc.log` 或 `/tmp/gcpsc.log` |

### 定时任务

安装后会自动添加 crontab 定时任务：
```bash
* * * * * /usr/local/bin/gcpsc check >/dev/null 2>&1
```

该任务每分钟执行一次，但只会检查到达检查间隔的实例。

## 💻 系统要求

### 支持的操作系统

- **Debian/Ubuntu** (推荐)
- **CentOS/RHEL** 7+
- **Rocky Linux/AlmaLinux**
- **Fedora**

### 必需权限

#### GCP 权限
服务账号需要以下权限：
- `compute.instances.get`
- `compute.instances.list`
- `compute.instances.start`
- `compute.zones.list`
- `resourcemanager.projects.get`

推荐角色：
- **Compute Instance Admin** (roles/compute.instanceAdmin)
- 或 **Compute Admin** (roles/compute.admin)

#### 系统权限
- 需要 root 或 sudo 权限运行

### 依赖组件

以下组件会自动安装：
- `gcloud` - Google Cloud SDK
- `jq` - JSON 处理工具
- `cron` - 定时任务服务

## 📊 使用示例

### 场景一：管理单个项目的 Spot 实例

```bash
# 1. 安装服务
sudo bash -c "$(curl -fsSL <script_url>)" @ install

# 2. 添加服务账号
sudo gcpsc
选择: 1 (账号管理)
选择: a (添加新账号)
选择: 1 (使用服务账号)
输入: /path/to/service-account.json

# 3. 自动发现实例
是否自动发现: y
检查间隔: 10

# 完成！实例已自动加入监控
```

### 场景二：批量管理多个账号

```bash
# 启动管理界面
sudo gcpsc

# 使用快速发现功能
选择: 2 (快速发现所有资源)
输入默认间隔: 5

# 系统会自动扫描所有已添加账号的新实例
```

### 场景三：调整监控策略

```bash
# 修改特定实例的检查间隔
sudo gcpsc
选择: 1 (账号管理)
选择账号
选择: 2 (修改实例检查间隔)
选择实例编号
输入新间隔: 30
```

## 🔍 故障排除

### 问题：无法连接到 GCP

**解决方案**：
1. 检查网络连接
2. 验证服务账号权限
3. 确认项目 ID 正确

### 问题：实例无法启动

**可能原因**：
- 配额限制
- 资源不足
- 实例配置问题

**解决方案**：
1. 检查 GCP 控制台的配额使用情况
2. 查看日志文件获取详细错误信息
3. 手动测试启动命令

### 问题：定时任务不执行

**检查步骤**：
```bash
# 查看定时任务
crontab -l

# 查看 cron 服务状态
systemctl status cron  # Debian/Ubuntu
systemctl status crond # CentOS/RHEL

# 查看日志
tail -f /var/log/gcpsc.log
```

## 📝 日志示例

正常运行日志：
```
[2025-01-11 10:30:00] [INFO] [user@example.com/project-123/asia-east1-b/instance-1] 状态: RUNNING
[2025-01-11 10:31:00] [WARN] [user@example.com/project-456/us-central1-a/instance-2] 不在运行状态，正在启动...
[2025-01-11 10:31:02] [INFO] [user@example.com/project-456/us-central1-a/instance-2] 启动命令已发送
[2025-01-11 10:31:35] [INFO] [user@example.com/project-456/us-central1-a/instance-2] 实例已成功启动
```

## 🤝 贡献指南

欢迎提交 Issue 和 Pull Request！

### 报告问题

请在 Issue 中包含：
1. 操作系统版本
2. 错误日志
3. 复现步骤

### 功能建议

我们欢迎新功能建议，特别是：
- 监控指标扩展
- 通知集成
- 性能优化

## 📄 许可证

本项目采用 MIT 许可证。详见 [LICENSE](LICENSE) 文件。

## 👨‍💻 作者

- **作者**: crazy0x70
- **GitHub**: [https://github.com/crazy0x70/scripts](https://github.com/crazy0x70/scripts)
- **版本**: 1.0.0
- **发布日期**: 2025-01-11

## 🌟 Star History

如果这个项目对您有帮助，请给个 Star ⭐ 支持一下！

---

<div align="center">

**[返回顶部](#gcp-spot-instance-保活服务)**

Made with ❤️ by crazy0x70

</div>
