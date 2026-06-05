import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:javbus/src/plugins/json_source_plugin.dart';
import 'package:javbus/src/plugins/magnet_item.dart';

const String _pluginJson = '''
{
  "schemaVersion": 1,
  "id": "laowang",
  "name": "老王磁力",
  "enabled": true,
  "baseUrl": "",
  "announcement": {
    "enabled": true,
    "url": "https://laowangfabu.com/",
    "urlPattern": "data-href=\\"([^\\"]+)\\"",
    "urlDecoding": "base64",
    "targetPattern": "最新地址"
  },
  "capabilities": {
    "requiresHumanVerification": true
  },
  "headers": {
    "User-Agent": "Mozilla/5.0"
  },
  "search": {
    "method": "GET",
    "url": "/search?keyword={query}&page={page}",
    "responseType": "html",
    "itemPattern": "<div>.*?</div>"
  },
  "fields": {
    "title": "title"
  },
  "defaults": {}
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('发布页插件协议', () {
    test('解析插件发布页配置', () {
      final JsonSourcePlugin plugin = parsePluginJson(_pluginJson);

      expect(plugin.id, 'laowang');
      expect(plugin.name, '老王磁力');
      expect(plugin.announcement, isNotNull);
      expect(plugin.announcement!.enabled, true);
      expect(plugin.announcement!.url, 'https://laowangfabu.com/');
      expect(plugin.announcement!.urlDecoding, 'base64');
      expect(plugin.announcement!.targetPattern, '最新地址');
      expect(plugin.capabilities.requiresHumanVerification, true);
    });

    test('从附近上下文优先提取目标地址', () {
      final String html =
          '''
            <li>
              备用地址
              <a data-href="aHR0cHM6Ly9vbGQuZXhhbXBsZS5jb20v"></a>
            </li>
          ''' +
          (' ' * 1200) +
          '''
            <li>
              最新地址
              <a class="ulink" data-href="aHR0cHM6Ly9uZXcuZXhhbXBsZS5jb20v"></a>
            </li>
          ''';

      const AnnouncementResolver resolver = AnnouncementResolver();
      final List<String> urls = resolver.extractUrls(
        html,
        'data-href="([^"]+)"',
        'base64',
        '最新地址',
      );

      expect(urls, isNotEmpty);
      expect(urls.first, 'https://new.example.com/');
    });

    test('targetPattern 命中地址保持页面顺序并去重', () {
      final String html =
          '''
            <li>最新地址 <a href="https://first.example.com/"></a></li>
            <li>最新地址 <a href="https://second.example.com/"></a></li>
            <li>最新地址 <a href="https://first.example.com/"></a></li>
          ''' +
          (' ' * 1200) +
          '''
            <li>备用地址 <a href="https://fallback.example.com/"></a></li>
          ''';

      const AnnouncementResolver resolver = AnnouncementResolver();
      final List<String> urls = resolver.extractUrls(
        html,
        'href="(https://[^"]+)"',
        'none',
        '最新地址',
      );

      expect(urls, <String>[
        'https://first.example.com/',
        'https://second.example.com/',
        'https://fallback.example.com/',
      ]);
    });

    test('支持未编码和 base64url 地址', () {
      const String html = '''
        <a href="https://plain.example.com/">plain</a>
        <a data-url="aHR0cHM6Ly91cmxzYWZlLmV4YW1wbGUuY29tLw">safe</a>
      ''';

      const AnnouncementResolver resolver = AnnouncementResolver();
      expect(
        resolver.extractUrls(html, 'href="(https://[^"]+)"', 'none', '').first,
        'https://plain.example.com/',
      );
      expect(
        resolver.extractUrls(html, 'data-url="([^"]+)"', 'base64url', '').first,
        'https://urlsafe.example.com/',
      );
    });

    test('支持发布页只返回裸域名', () {
      const String html = '''
        <script>
          var spans='b2suc29mYW4uaW4=';
          var href = "https://" + atob(spans);
        </script>
      ''';

      const AnnouncementResolver resolver = AnnouncementResolver();
      final List<String> urls = resolver.extractUrls(
        html,
        "var\\s+spans='([^']+)'",
        'base64',
        '',
      );

      expect(urls, <String>['https://ok.sofan.in']);
    });

    test('通过 HTTP 发布页刷新 registry 运行时地址', () async {
      final JsonSourcePlugin plugin = parsePluginJson(_pluginJson);
      final http.Client client = MockClient((http.Request request) async {
        expect(request.url.toString(), 'https://laowangfabu.com/');
        final String encoded = base64.encode(
          utf8.encode('https://resolved.example.com/'),
        );
        return http.Response.bytes(
          utf8.encode('<span>最新地址</span><a data-href="$encoded"></a>'),
          200,
          headers: <String, String>{'content-type': 'text/html; charset=utf-8'},
        );
      });
      final JsonPluginRegistry registry = JsonPluginRegistry(client: client);

      final String? resolved = await registry.refreshAnnouncementUrl(plugin);

      expect(resolved, 'https://resolved.example.com/');
      expect(
        registry.getResolvedBaseUrl(plugin.id),
        'https://resolved.example.com/',
      );
    });

    test('支持发布页多跳静态解析', () async {
      const String pluginJson = '''
{
  "schemaVersion": 1,
  "id": "multi-hop",
  "name": "多跳发布页",
  "enabled": true,
  "baseUrl": "",
  "announcement": {
    "enabled": true,
    "steps": [
      {
        "url": "https://release.example/",
        "urlPattern": "var\\\\s+spans='([^']+)'",
        "urlDecoding": "base64"
      },
      {
        "urlPattern": "host2\\\\s*=\\\\s*'([^']+)'",
        "urlDecoding": "none"
      }
    ]
  },
  "search": {
    "method": "GET",
    "url": "/s?word={query}",
    "responseType": "html",
    "itemPattern": "<div>.*?</div>"
  },
  "fields": {
    "title": "title"
  },
  "defaults": {}
}
''';
      final JsonSourcePlugin plugin = parsePluginJson(pluginJson);
      final http.Client client = MockClient((http.Request request) async {
        switch (request.url.toString()) {
          case 'https://release.example/':
            return http.Response("var spans='b2suc29mYW4uaW4v';", 200);
          case 'https://ok.sofan.in/':
            return http.Response("var host2 = 'to.sofan1.cc';", 200);
          default:
            fail('unexpected request: ${request.url}');
        }
      });
      final JsonPluginRegistry registry = JsonPluginRegistry(client: client);

      final String? resolved = await registry.refreshAnnouncementUrl(plugin);

      expect(resolved, 'https://to.sofan1.cc');
      expect(registry.getResolvedBaseUrl(plugin.id), 'https://to.sofan1.cc');
    });

    test('搜番草案插件配置可解析', () {
      final String raw = File('docs/发布页+多跳测试插件.json').readAsStringSync();
      final JsonSourcePlugin plugin = parsePluginJson(raw);

      expect(plugin.id, 'sefan');
      expect(plugin.name, '搜番');
      expect(plugin.announcement, isNotNull);
      expect(plugin.announcement!.steps, hasLength(2));
      expect(plugin.announcement!.steps.first.url, 'https://sefan.vip/');
      expect(
        plugin.announcement!.steps.first.urlPattern,
        "var\\s+spans='([^']+)'",
      );
      expect(plugin.announcement!.steps.first.urlDecoding, 'base64');
    });

    test('磁力多插件发布页三跳配置可解析', () async {
      const String pluginJson = '''
{
  "schemaVersion": 1,
  "id": "ki-dobt",
  "name": "磁力多",
  "enabled": true,
  "baseUrl": "",
  "announcement": {
    "enabled": true,
    "steps": [
      {
        "url": "https://ciliduo.org/",
        "urlPattern": "var\\\\s+spans='([^']+)'",
        "urlDecoding": "base64"
      },
      {
        "urlPattern": "host2\\\\s*=\\\\s*'([^']+)'",
        "urlDecoding": "none"
      },
      {
        "urlPattern": "atob\\\\('([^']+)'\\\\)",
        "urlDecoding": "base64"
      }
    ]
  },
  "search": {
    "method": "GET",
    "url": "/search?word={query}&host=dk.btdo.cc",
    "responseType": "html",
    "itemPattern": "<div>.*?</div>"
  },
  "fields": {
    "title": "title"
  },
  "defaults": {}
}
''';
      final JsonSourcePlugin plugin = parsePluginJson(pluginJson);

      expect(plugin.id, 'ki-dobt');
      expect(plugin.announcement, isNotNull);
      expect(plugin.announcement!.steps, hasLength(3));
      expect(plugin.search.url, contains('host=dk.btdo.cc'));

      final http.Client client = MockClient((http.Request request) async {
        switch (request.url.toString()) {
          case 'https://ciliduo.org/':
            return http.Response("var spans='Y2QubGluazUudG9w';", 200);
          case 'https://cd.link5.top':
            return http.Response("var host2 = 'dk.btdo.cc';", 200);
          case 'https://dk.btdo.cc':
            return http.Response(
              "var getProxy = function(){ var proxy = atob('aHR0cHM6Ly9kb2MyLmh0bWNkbi5jb206Mzk5ODg='); return proxy; };",
              200,
            );
          default:
            fail('unexpected request: ${request.url}');
        }
      });
      final JsonPluginRegistry registry = JsonPluginRegistry(client: client);

      final String? resolved = await registry.refreshAnnouncementUrl(plugin);

      expect(resolved, 'https://doc2.htmcdn.com:39988');
      expect(
        registry.getResolvedBaseUrl(plugin.id),
        'https://doc2.htmcdn.com:39988',
      );
    });

    test('模板变量区分原始值和编码值', () async {
      const String pluginJson = '''
{
  "schemaVersion": 1,
  "id": "template-vars",
  "name": "模板变量",
  "enabled": true,
  "baseUrl": "https://example.com",
  "search": {
    "method": "GET",
    "url": "/search?q={query}&raw={queryRaw}&p={page0}",
    "responseType": "html",
    "itemPattern": "<a href=\\"(?<sourceItemId>[^\\"]+)\\">(?<title>.*?)</a>"
  },
  "detail": {
    "method": "GET",
    "url": "{sourceItemId}",
    "responseType": "html",
    "itemPattern": "<a href=\\"(?<magnet>magnet:\\\\?xt=urn:btih:(?<infoHash>[A-Fa-f0-9]{40})[^\\"]*)\\">"
  },
  "fields": {
    "sourceItemId": "sourceItemId",
    "title": "title",
    "infoHash": "infoHash",
    "magnet": "magnet"
  },
  "defaults": {
    "webUrl": "{sourceItemId}"
  }
}
''';
      final JsonSourcePlugin plugin = parsePluginJson(pluginJson);

      expect(
        plugin.resolveSearchUrl(query: 'hello world/中文', page: 2).toString(),
        'https://example.com/search?q=hello%20world%2F%E4%B8%AD%E6%96%87&raw=hello%20world/%E4%B8%AD%E6%96%87&p=1',
      );
      final MagnetItem item = plugin
          .parseSearchHtml('<a href="/detail/path/abc 123">Title</a>', page: 1)
          .items
          .single;

      expect(item.webUrl, 'https://example.com/detail/path/abc%20123');
      expect(
        plugin.resolveDetailUrl(item).toString(),
        'https://example.com/detail/path/abc%20123',
      );
    });

    test('详情地址可显式使用编码后的 sourceItemId', () {
      const String pluginJson = '''
{
  "schemaVersion": 1,
  "id": "encoded-detail",
  "name": "编码详情",
  "enabled": true,
  "baseUrl": "https://example.com",
  "search": {
    "method": "GET",
    "url": "/search?q={query}",
    "responseType": "html",
    "itemPattern": "<a data-id=\\"(?<sourceItemId>[^\\"]+)\\">(?<title>.*?)</a>"
  },
  "detail": {
    "method": "GET",
    "url": "/detail/{sourceItemIdEncoded}",
    "responseType": "html",
    "itemPattern": "<span>(?<infoHash>[A-Fa-f0-9]{40})</span>"
  },
  "fields": {
    "sourceItemId": "sourceItemId",
    "title": "title",
    "infoHash": "infoHash"
  },
  "defaults": {}
}
''';
      final JsonSourcePlugin plugin = parsePluginJson(pluginJson);
      final MagnetItem item = plugin
          .parseSearchHtml('<a data-id="folder/a b">Title</a>', page: 1)
          .items
          .single;

      expect(
        plugin.resolveDetailUrl(item).toString(),
        'https://example.com/detail/folder%2Fa%20b',
      );
    });
  });
}
