# JSON 插件协议 v1

JAVBUS 的磁力搜索源只接受 JSON 插件。插件不执行脚本，只描述一个站点的请求地址、响应格式、字段映射、发布页解析方式和少量能力标记。

当前 v1 支持：

- `responseType: "html"`：请求网页源码，用正则提取搜索结果、详情和文件列表。
- `responseType: "json"`：请求 JSON API，用点路径读取字段。
- 只支持 `GET` 请求。
- 支持搜索页和详情页。
- 支持发布页解析最新 `baseUrl`，包括静态多跳。
- 支持 Cloudflare 等人机验证站点的 WebView 手动验证流程。

完整示例见 [example.json](example.json)。JSON 不能写 `//` 或 `/* */` 注释，示例使用 `_comment` 字段说明；解析器会忽略未知顶层字段。不要把注释字段放进 `headers`，否则会被当作真实 HTTP Header 发送。

## 安装与管理

应用本身不内置任何插件，插件需要用户自行安装。入口：

```text
设置 -> 插件目录
```

支持三种安装方式：

- 粘贴 JSON：直接粘贴插件文本。
- 选择 JSON 文件：本地选择 `.json` 文件。
- 从 URL 安装：输入以 `.json` 结尾的 URL，应用下载后安装。

插件保存到应用用户数据目录下的 `plugins` 子目录。文件名由 `id` 清理后生成，例如 `my-source.json`。如果编辑插件时修改了 `id`，旧文件会被删除并写入新文件。

## 顶层结构

```json
{
  "schemaVersion": 1,
  "id": "example-html",
  "name": "Example HTML Source",
  "enabled": true,
  "baseUrl": "https://example.com",
  "announcement": {
    "enabled": false,
    "url": "",
    "urlPattern": "",
    "urlDecoding": "none",
    "targetPattern": ""
  },
  "capabilities": {
    "requiresHumanVerification": false
  },
  "headers": {
    "User-Agent": "Mozilla/5.0"
  },
  "search": {},
  "detail": {},
  "fields": {},
  "fileFields": {},
  "defaults": {}
}
```

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `schemaVersion` | 否 | 协议版本，默认 `1`。 |
| `id` | 是 | 插件唯一 ID。建议小写英文、数字、短横线或下划线。 |
| `name` | 是 | UI 显示名称。 |
| `enabled` | 否 | 是否启用，默认 `true`。 |
| `baseUrl` | 条件必填 | 根地址。相对 URL 会基于它补全。没有启用 `announcement` 时必须是完整 URL。启用 `announcement` 时可以留空。 |
| `announcement` | 否 | 发布页配置，用于从发布站动态获取最新站点地址。 |
| `capabilities` | 否 | 插件能力标记。当前支持 `requiresHumanVerification`。 |
| `headers` | 否 | 全局请求头，会和 endpoint 内的 `headers` 合并；endpoint 同名 header 会覆盖全局值。 |
| `search` | 是 | 搜索 endpoint。 |
| `detail` | 否 | 详情 endpoint，用于补全 magnet、infoHash、文件列表等。 |
| `fields` | 是 | 资源字段映射。 |
| `fileFields` | 否 | 文件列表字段映射。 |
| `defaults` | 否 | 字段缺失时的默认模板。 |

## capabilities

```json
{
  "requiresHumanVerification": true
}
```

`requiresHumanVerification` 表示站点可能触发 Cloudflare 等人机验证。启用后，应用在 HTTP 响应疑似挑战页时会弹出 WebView，让用户手动验证。

验证完成后，应用会做两件事：

- 尝试读取页面 Cookie，供普通 HTTP 请求复用。
- 同时保留同 host 的 WebView 会话。后续搜索和详情会优先用已验证 WebView 静默加载 HTML，避免 HttpOnly Cookie 读不到时反复弹窗。

如果站点不需要验证，保持 `false` 或省略 `capabilities`。

## announcement

发布页用于应对站点频繁更换域名。解析出的地址只缓存在当前应用运行期内，不会改写插件 JSON。

单步发布页示例：

```json
{
  "enabled": true,
  "url": "https://example-fabu.com/",
  "urlPattern": "<a[^>]+data-href=\"([^\"]+)\"",
  "urlDecoding": "base64",
  "targetPattern": "最新地址"
}
```

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `enabled` | 否 | 是否启用发布页功能，默认 `false`。 |
| `url` | 条件必填 | 单步发布页地址。未使用 `steps` 时必填。 |
| `urlPattern` | 条件必填 | 单步提取正则。未使用 `steps` 时必填。使用第 1 个捕获组 `()` 捕获地址或编码后的地址。 |
| `urlDecoding` | 否 | 解码方式：`none`、`base64`、`base64url`、`hex`。默认 `none`。 |
| `targetPattern` | 否 | 优先关键词。应用会在命中位置附近约 500 个字符内查找该关键词，命中的候选地址优先使用。 |
| `steps` | 否 | 多跳发布页步骤。存在且非空时，优先使用 `steps`，忽略顶层 `url/urlPattern/urlDecoding/targetPattern`。 |

发布页解析出的地址可以是完整 URL，例如 `https://example.com/`；也可以是裸域名，例如 `example.com`，应用会补成 `https://example.com`。

### 多跳 steps

多跳用于处理“发布页 A 给出中转域名 B，中转页 B 的静态源码里再给出真实域名 C”的站点。它仍然是静态 HTTP + 正则解析，不执行 JavaScript，不进入 iframe。

```json
{
  "enabled": true,
  "steps": [
    {
      "url": "https://example-fabu.com/",
      "urlPattern": "var\\s+spans='([^']+)'",
      "urlDecoding": "base64",
      "targetPattern": "主站"
    },
    {
      "urlPattern": "host2\\s*=\\s*'([^']+)'",
      "urlDecoding": "none"
    }
  ]
}
```

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `url` | 条件必填 | 当前步骤请求地址。第 1 步必须填写完整 URL；第 2 步及之后可省略，省略时等同于 `"{value}"`。 |
| `urlPattern` | 是 | 当前步骤提取正则。使用第 1 个捕获组捕获地址或编码后的地址。 |
| `extract` | 否 | `urlPattern` 的别名。如果同时存在，优先使用 `urlPattern`。 |
| `urlDecoding` | 否 | 当前步骤解码方式：`none`、`base64`、`base64url`、`hex`。默认 `none`。 |
| `decode` | 否 | `urlDecoding` 的别名。如果同时存在，优先使用 `urlDecoding`。 |
| `targetPattern` | 否 | 当前步骤优先关键词。行为和单步一致：在命中位置附近约 500 个字符内查找关键词。 |

第 2 步及之后的 `url` 支持变量：

| 变量 | 说明 |
| --- | --- |
| `{value}` / `{url}` | 上一步解析出的完整 URL。 |
| `{origin}` | 上一步 URL 的 origin，例如 `https://example.com:8443`。 |
| `{host}` | 上一步 URL 的 host，例如 `example.com`。 |

候选地址排序规则：

- 命中 `targetPattern` 的候选优先。
- 同一优先级内保持页面出现顺序。
- 重复地址会去重。

发布页检查时机：

1. 首次安装：首次安装启用发布页的插件时，必须先成功解析最新地址；失败则不保存插件。
2. 首次搜索兜底：应用重启后运行时缓存会清空，搜索前会先尝试解析发布页。
3. 搜索失败：普通搜索失败时会刷新发布页并用新地址重试一次。
4. 手动刷新：插件管理页会为启用发布页的插件显示刷新按钮。

注意：

- `announcement.enabled` 为 `true` 时，`baseUrl` 可以留空。
- 搜索失败触发的发布页重试不会吞掉人机验证异常；需要验证时仍会弹 WebView。
- 多跳不执行 JavaScript，不处理 iframe 拼 URL。需要找到最终直出的 HTML/API 地址后再写插件。

## 模板变量

模板变量用于 `search.url`、`detail.url` 和 `defaults`。

搜索变量：

| 变量 | 说明 |
| --- | --- |
| `{query}` | 搜索关键词，已做 `Uri.encodeComponent` 编码。 |
| `{queryRaw}` | 搜索关键词原始值。生成最终 `Uri` 时，Dart 仍会按 URI 规则规范化空格和非 ASCII 字符。 |
| `{queryBase64}` | 搜索关键词的 UTF-8 URL-safe Base64，去掉末尾 `=`。 |
| `{page}` | 从 `1` 开始的页码。 |
| `{page0}` | 从 `0` 开始的页码。 |

详情和默认值变量：

| 变量 | 说明 |
| --- | --- |
| `{sourceItemId}` | 搜索结果中的源站条目 ID。常用于详情页路径。保持原始值，适合 `/detail/abc` 这种相对路径。 |
| `{sourceItemIdEncoded}` | URL 编码后的 `sourceItemId`。适合 `/detail/{sourceItemIdEncoded}` 这种 ID 需要作为单一路径段的站点。 |
| `{infoHash}` | info hash，通常为大写。 |
| `{infoHashLower}` | 小写 info hash。 |
| `{infoHashUpper}` | 大写 info hash。 |
| `{infoHashEncoded}` / `{infoHashLowerEncoded}` / `{infoHashUpperEncoded}` | 对应值的 URL 编码版本。 |

重要：当前实现不会在模板替换时对所有变量统一编码。变量是否编码由变量名决定，例如 `{query}` 已编码、`{sourceItemId}` 未编码、`{sourceItemIdEncoded}` 已编码。

## Endpoint

`search` 和 `detail` 使用同一种结构。

```json
{
  "method": "GET",
  "url": "/search?q={query}&page={page}",
  "responseType": "html",
  "headers": {},
  "itemsPath": "data.items",
  "totalPath": "data.total",
  "currentPagePath": "data.page",
  "lastPagePath": "data.lastPage",
  "rootPath": "data",
  "filesPath": "files",
  "rootPattern": "",
  "itemPattern": "",
  "fileRootPattern": "",
  "filePattern": "",
  "totalPattern": "",
  "lastPagePattern": "",
  "pageSize": 20
}
```

通用字段：

| 字段 | 说明 |
| --- | --- |
| `method` | 当前只支持 `GET`。 |
| `url` | 请求 URL。可写绝对 URL，也可写相对 `baseUrl` 的路径。 |
| `responseType` | `html` 或 `json`，默认 `json`。 |
| `headers` | endpoint 专用请求头，会覆盖同名全局 header。 |
| `pageSize` | 每页数量，默认 `20`。用于根据 `total` 推算最后一页。 |

JSON endpoint 字段：

| 字段 | 用于 | 说明 |
| --- | --- | --- |
| `itemsPath` | search | 搜索结果数组路径。 |
| `totalPath` | search | 总结果数路径。 |
| `currentPagePath` | search | 当前页路径。缺失时使用请求页码。 |
| `lastPagePath` | search | 最后一页路径。缺失时用 `total / pageSize` 推算。 |
| `rootPath` | detail | 详情对象路径。为空时使用响应根对象。 |
| `filesPath` | detail | 文件列表数组路径。 |

路径使用点号访问对象，例如 `data.items`、`meta.total`。数组可用数字下标，例如 `data.0.name`。

HTML endpoint 字段：

| 字段 | 用于 | 说明 |
| --- | --- | --- |
| `rootPattern` | search/detail | 可选。先用正则截取局部 HTML 范围；优先使用第 1 个捕获组。 |
| `itemPattern` | search/detail | 必填。匹配一个资源条目或详情页主体信息。 |
| `fileRootPattern` | detail | 可选。先截取文件列表区域；优先使用第 1 个捕获组。 |
| `filePattern` | detail | 可选。匹配文件列表中的一个文件。 |
| `totalPattern` | search | 可选。匹配总结果数，使用第 1 个捕获组。 |
| `lastPagePattern` | search | 可选。匹配最后一页页码，使用第 1 个捕获组。 |

HTML 正则参数：

- `caseSensitive: false`
- `dotAll: true`
- `multiLine: true`

正则提取支持两种方式：

1. 命名捕获组：捕获组名使用字段路径最后一段，例如 `(?<infoHash>[A-Fa-f0-9]{40})`。
2. 顺序捕获组：如果正则没有命名捕获组，会按 `fields` 或 `fileFields` 中字段出现顺序依次取第 1、2、3... 个捕获组。

HTML 捕获值会做基础清理：

- 去掉 HTML 标签。
- 解码 `&nbsp;`、`&#160;`、`&#xA0;`、`&amp;`、`&quot;`、`&#39;`、`&lt;`、`&gt;`。
- 合并空白字符。

JSON 字符串里的反斜杠要转义，例如正则 `\s` 要写成 `\\s`。

## fields

`fields` 把应用内部字段映射到 JSON 路径，或映射到 HTML 正则捕获组名。

```json
{
  "sourceItemId": "sourceItemId",
  "title": "title",
  "infoHash": "infoHash",
  "magnet": "magnet",
  "size": "size",
  "humanSize": "humanSize",
  "seeders": "seeders",
  "leechers": "leechers",
  "score": "score",
  "health": "health",
  "verified": "verified",
  "largestFile": "largestFile",
  "webUrl": "webUrl",
  "createdAt": "createdAt",
  "lastSeen": "lastSeen"
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `sourceItemId` | string | 源站详情 ID。缺失时使用 `infoHash`。搜索结果最终必须得到该字段，否则列表项会被丢弃。 |
| `title` | string | 资源标题。 |
| `infoHash` | string | 建议提供。详情页可补全；有它才能通过 `defaults.magnet` 生成 magnet。 |
| `magnet` | string | 磁力链接。可直接提取，也可由 `defaults.magnet` 生成。 |
| `size` | int | 字节数。 |
| `humanSize` | string | 人类可读大小，例如 `1.23 GB`。 |
| `seeders` | int | 做种、热度或访问指标。不同站点含义可能不同。 |
| `leechers` | int | 下载、请求或热度指标。不同站点含义可能不同。 |
| `score` | double | 排序或评分。 |
| `health` | double | 健康度、文件数或其它站点指标。 |
| `verified` | bool | 是否验证。 |
| `largestFile` | string | 最大文件名或文件摘要。 |
| `webUrl` | string | 源站详情页。相对地址会基于当前有效 `baseUrl` 补全。 |
| `createdAt` | ISO date string | 创建时间。 |
| `lastSeen` | ISO date string | 最近发现时间。 |

## fileFields

详情页可返回文件列表。

```json
{
  "path": "path",
  "size": "size",
  "humanSize": "humanSize"
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `path` | string | 文件路径或文件名。 |
| `size` | int | 字节数。 |
| `humanSize` | string | 人类可读大小。 |

## defaults

`defaults` 用于字段缺失时生成值。

```json
{
  "magnet": "magnet:?xt=urn:btih:{infoHashUpper}",
  "webUrl": "{sourceItemId}"
}
```

常见用途：

- 列表页只返回 `infoHash`，用 `defaults.magnet` 生成 magnet。
- 列表页只返回 `infoHash`，用 `defaults.webUrl` 生成详情页链接。
- HTML 列表页返回详情相对地址，先放到 `sourceItemId`，再用 `detail.url: "{sourceItemId}"` 和 `defaults.webUrl: "{sourceItemId}"`。

## 示例

### JSON API

```json
{
  "schemaVersion": 1,
  "id": "example-api",
  "name": "Example API",
  "enabled": true,
  "baseUrl": "https://example.com",
  "search": {
    "method": "GET",
    "url": "/api/search?q={query}&page={page}",
    "responseType": "json",
    "itemsPath": "data.items",
    "totalPath": "data.total",
    "currentPagePath": "data.page",
    "lastPagePath": "data.lastPage",
    "pageSize": 20
  },
  "detail": {
    "method": "GET",
    "url": "/api/torrent/{infoHashLower}",
    "responseType": "json",
    "rootPath": "data",
    "filesPath": "files"
  },
  "fields": {
    "sourceItemId": "id",
    "title": "title",
    "infoHash": "hash",
    "size": "bytes",
    "seeders": "seeders",
    "leechers": "leechers",
    "createdAt": "createdAt"
  },
  "fileFields": {
    "path": "name",
    "size": "bytes"
  },
  "defaults": {
    "magnet": "magnet:?xt=urn:btih:{infoHashUpper}",
    "webUrl": "/torrent/{infoHashLower}"
  }
}
```

### HTML 正则

假设搜索结果 HTML 类似：

```html
<div class="item">
  <a href="/detail/abc123">Example Title</a>
  <span class="hash">0123456789abcdef0123456789abcdef01234567</span>
  <span class="size">1.2 GB</span>
</div>
```

插件可写成：

```json
{
  "schemaVersion": 1,
  "id": "example-html",
  "name": "Example HTML",
  "enabled": true,
  "baseUrl": "https://example.com",
  "headers": {
    "User-Agent": "Mozilla/5.0"
  },
  "search": {
    "method": "GET",
    "url": "/search?q={query}&page={page}",
    "responseType": "html",
    "pageSize": 20,
    "rootPattern": "<div class=\"result-list\">([\\s\\S]*?)<nav",
    "itemPattern": "<div class=\"item\">\\s*<a href=\"(?<sourceItemId>[^\"]+)\">(?<title>.*?)</a>\\s*<span class=\"hash\">(?<infoHash>[A-Fa-f0-9]{40})</span>\\s*<span class=\"size\">(?<humanSize>.*?)</span>\\s*</div>",
    "totalPattern": "(\\d+)\\s+results",
    "lastPagePattern": "page=(\\d+)\">Last"
  },
  "detail": {
    "method": "GET",
    "url": "{sourceItemId}",
    "responseType": "html",
    "itemPattern": "<h1[^>]*>(?<title>.*?)</h1>[\\s\\S]*?<a href=\"(?<magnet>magnet:\\?xt=urn:btih:(?<infoHash>[A-Fa-f0-9]{40})[^\"]*)\"",
    "fileRootPattern": "<ul class=\"files\">([\\s\\S]*?)</ul>",
    "filePattern": "<li>\\s*<span class=\"path\">(?<path>.*?)</span>\\s*<span class=\"size\">(?<humanSize>.*?)</span>\\s*</li>"
  },
  "fields": {
    "sourceItemId": "sourceItemId",
    "title": "title",
    "infoHash": "infoHash",
    "magnet": "magnet",
    "humanSize": "humanSize",
    "webUrl": "sourceItemId"
  },
  "fileFields": {
    "path": "path",
    "humanSize": "humanSize"
  },
  "defaults": {
    "magnet": "magnet:?xt=urn:btih:{infoHashUpper}",
    "webUrl": "{sourceItemId}"
  }
}
```

## 调试建议

1. 先用浏览器确认搜索 URL 能访问，且返回的是静态 HTML 或 JSON。
2. HTML 插件先写 `rootPattern` 和 `itemPattern`，确认列表能匹配，再补详情页。
3. 如果列表页只给详情链接，把它映射到 `sourceItemId`，再用 `detail.url: "{sourceItemId}"`。
4. 如果详情 ID 需要作为单一路径段编码，使用 `{sourceItemIdEncoded}`。
5. 如果没有 magnet 字段，只要能拿到 `infoHash`，就用 `defaults.magnet` 生成。
6. 如果站点触发 Cloudflare，把 `capabilities.requiresHumanVerification` 设为 `true`。
7. 如果站点频繁更换域名，配置 `announcement` 指向发布页。
8. URL 安装要求地址以 `.json` 结尾。

## 当前限制

- 只支持 `GET`。
- 没有登录表单流程。
- 没有 JavaScript 渲染爬取能力；人机验证只用于获取页面 HTML 或 Cookie。纯 JS 跳转、iframe 渲染或前端二次请求站点，需要找出最终直出的 HTML/API 地址后再写插件。
- HTML 解析基于正则，适合结构稳定、重复项明显的站点。
- Cookie 只保存在当前应用运行期内。CF 等站点优先依赖已验证 WebView 会话复用。
- URL 安装只接受 `.json` 结尾地址。
