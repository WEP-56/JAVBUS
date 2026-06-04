# JAVBUS

JAVBUS 是一个基于 JSON 插件的磁力资源搜索器，同时提供网盘搜索、收藏管理和轻量的局域网文本/文件互传能力。

- 磁力搜索：通过用户自行安装的 JSON 插件接入搜索源，软件本身不内置资源站插件。
- 搜盘：支持配置自部署的 [PanSou](https://github.com/fish2018/pansou) API 服务地址和密钥。
- 收藏：管理磁力链、网盘链接和普通链接。
- 局域网互传：在可信局域网内发现设备，并发送文本或文件。

## 插件协议

插件协议文档见 [docs/json_plugin_v1.md](docs/json_plugin_v1.md)。

当前 v1 支持：

- JSON API 搜索源
- HTML + 正则提取搜索源
- Cloudflare 人机验证弹窗标记
- `GET` 请求

## 局域网互传

局域网互传模块参考了 [LocalSend](https://github.com/localsend/localsend) 的产品思路和局域网发现/传输架构。当前实现是轻量自定义协议：UDP 广播发现设备，本地 HTTP 接收文本和文件，历史记录只保存必要元数据。

## 开发验证

```powershell
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
flutter build windows --debug --no-pub
flutter build apk --debug --no-pub
```

## License

MIT
