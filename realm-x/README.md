# 支持的系统架构

脚本自动检测并支持以下架构：

- x86_64
- ARM64/aarch64
- ARMv7
- ARM

# 一键安装

```
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/crazy0x70/scripts/refs/heads/main/realm-x/realm-install.sh)"
```

# 使用方法

```
# 显示交互式菜单
realm-x

# 或使用命令行参数
realm-x -h  # 显示帮助
```

## 命令参数

realm-x支持以下命令行参数：

|      参数       |       描述        |
| :-------------: | :---------------: |
|   -h, --help    |   显示帮助信息    |
|  -i, --install  |  安装或更新Realm  |
|  -s, --status   | 查看Realm服务状态 |
|  -r, --restart  |   重启Realm服务   |
|   -l, --list    | 列出当前转发规则  |
|    -a, --add    | 添加新的转发规则  |
|   -e, --edit    |   编辑配置文件    |
|   -m, --mptcp    |   管理MPTCP设置    |
| -u, --uninstall |     卸载Realm     |

## 配置文件位置

- Realm二进制文件: `/usr/local/bin/realm`
- 配置文件: `/usr/local/etc/realm/realm.toml`
- 服务文件: `/etc/systemd/system/realm.service`

# 注意事项

- 大多数操作需要root权限
- 卸载操作会完全移除Realm和realm-x工具
- 卸载时可选择保留配置文件，便于将来重新安装

# 许可

本项目遵循MIT许可证。详情请参阅LICENSE文件。
