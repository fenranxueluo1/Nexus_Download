# Nexus Download

基于 Flutter 的哔哩哔哩媒体解析与归档工具，支持 Android、iOS、Windows、macOS 与 Linux。

## 功能

- 解析视频、番剧、课程、收藏夹、合集、系列、创作者投稿与稍后再看
- 分片下载、断点续传、并发任务、限速与 HTTP 代理
- 视频/音频下载与合并，字幕、弹幕、封面与 NFO 导出
- 扫码登录与 Cookie 导入
- 路径模板、输出方案、任务日志与完成记录

## 运行

```bash
flutter pub get
flutter run
```

桌面端合并音视频需要 FFmpeg；Android 使用系统 MediaMuxer，iOS 使用 AVFoundation，均只支持 MP4/M4A。

## 许可证

本项目使用 **GNU General Public License v3.0**，详见 [LICENSE](LICENSE)。