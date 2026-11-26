<!-- 作者：huangxiaofeng · 创建日期：2026-11-26 -->

# 闲鱼助手（macOS 菜单栏 App）

在后台拉起并守护本仓库的 4 个服务（后台接口 / 消息收发 / 定时任务 / 管理网页），退出即全部停止。

- 首次打开自动安装运行环境（Homebrew 依赖、MySQL、Redis、Python / Node 依赖、浏览器），代码来自本 fork
- 菜单：打开管理后台、重启服务、查看日志、导出 / 导入数据、更新程序代码、防止电脑休眠、登录时自动打开

## 编译

```bash
./build.sh            # 产物在 build/，并打包成可分发的 zip
./build.sh --install  # 另外安装到 /Applications 并启动
```

## 目录

| 路径 | 说明 |
|---|---|
| `main.swift` | App 主程序（服务守护、菜单、防休眠） |
| `Shared/FishShape.swift` | 小鱼图形，应用图标与菜单栏图标共用 |
| `IconTool/main.swift` | 打包时生成 AppIcon.icns |
| `Resources/setup.sh` | 运行环境安装 / 更新脚本 |
| `Resources/data.sh` | 数据导出 / 导入脚本 |
