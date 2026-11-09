# IPCC 提取工具

[简体中文](README.md) | [English](README.en.md)

一款适用于 macOS 的工具，从 iPhone 和蜂窝版 iPad 固件中查找并导出运营商配置包。

## 下载安装

从 [Releases](https://github.com/Today1314/IPCC-Extractor/releases) 下载 Apple Silicon 安装包，打开后将应用拖入“应用程序”。覆盖旧版前，请先正常退出旧版。首个公开版本为 **1.0 Beta**，此前单独分享的 1.5 版是它的前身。

需要 Apple Silicon Mac 和 macOS 14 或更新版本。应用使用临时签名，未经过 Apple 公证；如果系统阻止打开，请查看“系统设置 → 隐私与安全性”。

## 使用

选择本地 IPSW 固件、已解密的映像或提取后的文件夹，确认固件信息后勾选运营商并导出。应用内可切换中文和英文。

AEA 加密映像需要联网获取 Apple 的解密资料，固件解密、扫描和导出均在本机进行，不上传整个固件。正常退出或切换固件时会清理应用创建的临时文件；处理期间请勿强制退出。

导出时检查压缩包结构与文件内容；这不代表已验证 Apple 签名、设备兼容性或实际安装成功。部分固件可能无法直接访问，具体原因以应用内提示为准。

## 从源码构建

安装 Apple 命令行工具以及支持 arm64 的 macOS Python 3.13 framework，然后执行：

```sh
PYTHON_FRAMEWORK=/Library/Frameworks/Python.framework bash ./build.sh
```

可通过 `OUTPUT_DIR` 修改输出目录。脚本会将提供的 Python framework 复制进应用；分发时须保留 Python 的许可证和声明。脚本构建的应用使用临时签名，未经过公证。Apple 的系统框架及 `aea`、`hdiutil` 等工具由 macOS 提供，不包含在此仓库中。

## 源码与分发

源码公开供查看，目前尚未选择开源许可证；复用或再分发本项目代码及图标前，请先取得仓库所有者的许可。安装包中的 Python 运行环境遵循其自身的许可证与声明，相关文件包含在应用内。本项目不分发固件或运营商配置包。
