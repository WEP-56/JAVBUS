import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../magnets/magnet_library.dart';
import '../pan/pan_search_client.dart';

class PanSearchSection extends StatefulWidget {
  const PanSearchSection({super.key});

  @override
  State<PanSearchSection> createState() => _PanSearchSectionState();
}

class _PanSearchSectionState extends State<PanSearchSection> {
  final PanSearchClient _client = PanSearchClient();
  final MagnetLibrary _library = MagnetLibrary();
  final TextEditingController _queryController = TextEditingController();

  bool _loading = false;
  String? _message;
  PanSearchResult? _result;

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: <Widget>[
        SliverToBoxAdapter(child: _buildSearchBox()),
        if (_message != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _PanInfoStrip(message: _message!),
            ),
          ),
        if (_loading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: 12),
              child: _PanLoadingStrip(message: '正在搜索网盘资源...'),
            ),
          )
        else if (_result == null)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: 46),
              child: _PanEmptyState(),
            ),
          )
        else if (_result!.groups.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: 46),
              child: _PanNoResultState(),
            ),
          )
        else ...<Widget>[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(2, 18, 2, 10),
              child: _PanSectionLead(
                title: '搜盘结果',
                subtitle: '${_result!.groups.length} 个网盘分组',
                trailing: '${_result!.total} 条',
              ),
            ),
          ),
          SliverList.separated(
            itemBuilder: (BuildContext context, int index) {
              final PanResultGroup group = _result!.groups[index];
              return _PanGroupCard(
                group: group,
                onCopy: _copyShare,
                onSave: _saveShare,
              );
            },
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemCount: _result!.groups.length,
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 10)),
        ],
      ],
    );
  }

  Widget _buildSearchBox() {
    return _PanSurface(
      padding: const EdgeInsets.all(10),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool compact = constraints.maxWidth < 720;
          final Widget input = _PanCommandInput(
            controller: _queryController,
            loading: _loading,
            onSearch: _search,
          );
          final Widget button = SizedBox(
            height: 42,
            child: FilledButton.icon(
              onPressed: _loading ? null : _search,
              icon: _loading
                  ? const SizedBox.square(
                      dimension: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_forward_rounded, size: 18),
              label: Text(_loading ? '处理中' : '搜盘'),
            ),
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[input, const SizedBox(height: 10), button],
            );
          }

          return Row(
            children: <Widget>[
              Expanded(child: input),
              const SizedBox(width: 10),
              button,
            ],
          );
        },
      ),
    );
  }

  Future<void> _search() async {
    final String query = _queryController.text.trim();
    if (query.isEmpty) {
      _showSnack('请输入网盘搜索关键词');
      return;
    }

    setState(() {
      _loading = true;
      _message = null;
      _result = null;
    });

    try {
      final PanSearchResult result = await _client.search(keyword: query);
      if (!mounted) {
        return;
      }
      setState(() {
        _result = result;
        _message = '搜盘返回 ${result.total} 条资源。';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _message = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _copyShare(PanShareItem item) async {
    final String text = item.password.isEmpty
        ? item.url
        : '${item.url}\n提取码：${item.password}';
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      _showSnack('已复制网盘链接');
    }
  }

  Future<void> _saveShare(PanShareItem item) async {
    try {
      await _library.upsert(
        newStoredFavorite(
          id: 'pan_${_stableId(item.url)}',
          kind: FavoriteKind.pan,
          title: item.title,
          url: item.url,
          password: item.password,
          tags: <String>[_cloudLabel(item.cloudType)],
          note: item.note,
          source: item.source,
        ),
      );
      if (mounted) {
        _showSnack('已保存到收藏');
      }
    } on Object catch (error) {
      if (mounted) {
        _showSnack('收藏失败：$error');
      }
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(appSnack(message));
  }
}

class _PanCommandInput extends StatelessWidget {
  const _PanCommandInput({
    required this.controller,
    required this.loading,
    required this.onSearch,
  });

  final TextEditingController controller;
  final bool loading;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: AppTheme.elevated(context),
        border: Border.all(color: AppTheme.border(context)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: <Widget>[
          const SizedBox(width: 13),
          Icon(Icons.cloud_rounded, color: AppTheme.text3(context), size: 19),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              enabled: !loading,
              autofocus: true,
              decoration: InputDecoration(
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: EdgeInsets.zero,
                hintText: '输入片名、剧名或关键词',
                hintStyle: TextStyle(color: AppTheme.text3(context)),
              ),
              style: TextStyle(
                color: AppTheme.text1(context),
                fontSize: 14,
                height: 1.2,
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => onSearch(),
            ),
          ),
          const SizedBox(width: 10),
        ],
      ),
    );
  }
}

class _PanGroupCard extends StatefulWidget {
  const _PanGroupCard({
    required this.group,
    required this.onCopy,
    required this.onSave,
  });

  final PanResultGroup group;
  final ValueChanged<PanShareItem> onCopy;
  final ValueChanged<PanShareItem> onSave;

  @override
  State<_PanGroupCard> createState() => _PanGroupCardState();
}

class _PanGroupCardState extends State<_PanGroupCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final List<PanShareItem> visibleItems = _expanded
        ? widget.group.items
        : widget.group.items.take(8).toList(growable: false);
    final int hiddenCount = widget.group.items.length - visibleItems.length;

    return _PanSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              _CloudBadge(type: widget.group.cloudType),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _cloudLabel(widget.group.cloudType),
                  style: TextStyle(
                    color: AppTheme.text1(context),
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
              ),
              _SmallCountBadge(text: '${widget.group.items.length} 条'),
            ],
          ),
          const SizedBox(height: 10),
          for (final PanShareItem item in visibleItems) ...<Widget>[
            _PanShareRow(
              item: item,
              onCopy: widget.onCopy,
              onSave: widget.onSave,
            ),
            if (item != visibleItems.last)
              Divider(color: AppTheme.border(context), height: 14),
          ],
          if (widget.group.items.length > 8)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _expanded
                          ? '已显示全部 ${widget.group.items.length} 条结果'
                          : '还有 $hiddenCount 条结果未显示',
                      style: TextStyle(
                        color: AppTheme.text3(context),
                        fontSize: 12,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => setState(() => _expanded = !_expanded),
                    icon: Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                    ),
                    label: Text(_expanded ? '收起' : '展开'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PanShareRow extends StatelessWidget {
  const _PanShareRow({
    required this.item,
    required this.onCopy,
    required this.onSave,
  });

  final PanShareItem item;
  final ValueChanged<PanShareItem> onCopy;
  final ValueChanged<PanShareItem> onSave;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppTheme.text1(context),
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: <Widget>[
                    if (item.password.isNotEmpty)
                      _MiniMeta(text: '提取码 ${item.password}'),
                    if (item.source.isNotEmpty) _MiniMeta(text: item.source),
                    if (item.datetime != null)
                      _MiniMeta(text: _formatDate(item.datetime!)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          IconButton(
            onPressed: () => onCopy(item),
            icon: const Icon(Icons.copy_rounded, size: 18),
            tooltip: '复制',
          ),
          IconButton(
            onPressed: () => onSave(item),
            icon: const Icon(Icons.bookmark_add_rounded, size: 18),
            tooltip: '保存到收藏',
          ),
        ],
      ),
    );
  }
}

class _CloudBadge extends StatelessWidget {
  const _CloudBadge({required this.type});

  final String type;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: AppTheme.accentDim(context),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(_cloudIcon(type), color: AppTheme.accent(context), size: 20),
    );
  }
}

class _MiniMeta extends StatelessWidget {
  const _MiniMeta({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(color: AppTheme.text3(context), fontSize: 12),
    );
  }
}

class _SmallCountBadge extends StatelessWidget {
  const _SmallCountBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: AppTheme.elevated(context),
        border: Border.all(color: AppTheme.border(context)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: AppTheme.text2(context),
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _PanSectionLead extends StatelessWidget {
  const _PanSectionLead({
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final String title;
  final String subtitle;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: TextStyle(
                  color: AppTheme.text1(context),
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: TextStyle(color: AppTheme.text3(context), fontSize: 12),
              ),
            ],
          ),
        ),
        _SmallCountBadge(text: trailing),
      ],
    );
  }
}

class _PanInfoStrip extends StatelessWidget {
  const _PanInfoStrip({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return _PanSurface(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.info_outline_rounded,
            color: AppTheme.accent(context),
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: AppTheme.text2(context), fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _PanLoadingStrip extends StatelessWidget {
  const _PanLoadingStrip({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return _PanSurface(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Row(
        children: <Widget>[
          const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: AppTheme.text2(context), fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _PanEmptyState extends StatelessWidget {
  const _PanEmptyState();

  @override
  Widget build(BuildContext context) {
    return const _CenteredState(
      icon: Icons.cloud_queue_rounded,
      title: '输入关键词后开始搜盘',
      subtitle: '结果会按网盘类型分组显示，可复制链接或用浏览器打开。',
    );
  }
}

class _PanNoResultState extends StatelessWidget {
  const _PanNoResultState();

  @override
  Widget build(BuildContext context) {
    return const _CenteredState(
      icon: Icons.search_off_rounded,
      title: '没有搜到网盘资源',
      subtitle: '可以减少筛选的网盘类型，或换一个关键词再试。',
    );
  }
}

class _CenteredState extends StatelessWidget {
  const _CenteredState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            color: AppTheme.elevated(context),
            border: Border.all(color: AppTheme.border(context)),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: AppTheme.text3(context), size: 26),
        ),
        const SizedBox(height: 14),
        Text(
          title,
          style: TextStyle(
            color: AppTheme.text1(context),
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: TextStyle(color: AppTheme.text3(context), fontSize: 12),
        ),
      ],
    );
  }
}

class _PanSurface extends StatelessWidget {
  const _PanSurface({
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppTheme.surface(context),
        border: Border.all(color: AppTheme.border(context)),
        borderRadius: BorderRadius.circular(12),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(
              alpha: AppTheme.isDark(context) ? 0.20 : 0.04,
            ),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: child,
    );
  }
}

String _cloudLabel(String type) {
  return switch (type) {
    'baidu' => '百度',
    'aliyun' => '阿里',
    'quark' => '夸克',
    'tianyi' => '天翼',
    'uc' => 'UC',
    'mobile' => '移动',
    '115' => '115',
    'pikpak' => 'PikPak',
    'xunlei' => '迅雷',
    '123' => '123',
    'magnet' => '磁力',
    'ed2k' => 'ED2K',
    _ => type,
  };
}

IconData _cloudIcon(String type) {
  return switch (type) {
    'magnet' => Icons.link_rounded,
    'ed2k' => Icons.hub_rounded,
    'xunlei' => Icons.bolt_rounded,
    _ => Icons.cloud_rounded,
  };
}

String _formatDate(DateTime value) {
  final DateTime local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}

String _stableId(String value) {
  var hash = 2166136261;
  for (final int codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 16777619) & 0xFFFFFFFF;
  }
  return hash.toUnsigned(32).toRadixString(16).padLeft(8, '0');
}
