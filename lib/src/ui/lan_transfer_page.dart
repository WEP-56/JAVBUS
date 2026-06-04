import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../lan/lan_models.dart';
import '../lan/lan_transfer_service.dart';

class LanTransferPage extends StatefulWidget {
  const LanTransferPage({required this.service, super.key});

  final LanTransferService service;

  @override
  State<LanTransferPage> createState() => _LanTransferPageState();
}

class _LanTransferPageState extends State<LanTransferPage> {
  final TextEditingController _textController = TextEditingController();

  String? _selectedPeerId;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.service.start());
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.service,
      builder: (BuildContext context, _) {
        final LanPeer? selectedPeer = _selectedPeer(widget.service.peers);
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool compact = constraints.maxWidth < 760;
            if (compact) {
              return CustomScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: <Widget>[
                  SliverToBoxAdapter(
                    child: _StatusPanel(service: widget.service),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 12)),
                  SliverToBoxAdapter(
                    child: _PeerPanel(
                      peers: widget.service.peers,
                      selectedPeerId: _selectedPeerId,
                      onSelect: _selectPeer,
                      onRefresh: widget.service.announce,
                      onAddManual: _addManualPeer,
                      fillAvailableHeight: false,
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 12)),
                  SliverToBoxAdapter(
                    child: _SendPanel(
                      controller: _textController,
                      peer: selectedPeer,
                      sending: _sending,
                      onSendText: () => _sendText(selectedPeer),
                      onSendFile: () => _sendFile(selectedPeer),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 12)),
                  SliverToBoxAdapter(
                    child: _HistoryPanel(
                      records: widget.service.history,
                      onClear: widget.service.clearHistory,
                      onCopyText: _copyText,
                      fillAvailableHeight: false,
                    ),
                  ),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(
                  width: 292,
                  child: Column(
                    children: <Widget>[
                      _StatusPanel(service: widget.service),
                      const SizedBox(height: 12),
                      Expanded(
                        child: _PeerPanel(
                          peers: widget.service.peers,
                          selectedPeerId: _selectedPeerId,
                          onSelect: _selectPeer,
                          onRefresh: widget.service.announce,
                          onAddManual: _addManualPeer,
                          fillAvailableHeight: true,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    children: <Widget>[
                      _SendPanel(
                        controller: _textController,
                        peer: selectedPeer,
                        sending: _sending,
                        onSendText: () => _sendText(selectedPeer),
                        onSendFile: () => _sendFile(selectedPeer),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: _HistoryPanel(
                          records: widget.service.history,
                          onClear: widget.service.clearHistory,
                          onCopyText: _copyText,
                          fillAvailableHeight: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  LanPeer? _selectedPeer(List<LanPeer> peers) {
    if (peers.isEmpty) {
      return null;
    }
    final String? selectedId = _selectedPeerId;
    if (selectedId != null) {
      for (final LanPeer peer in peers) {
        if (peer.id == selectedId) {
          return peer;
        }
      }
    }
    return peers.first;
  }

  void _selectPeer(LanPeer peer) {
    setState(() => _selectedPeerId = peer.id);
  }

  Future<void> _sendText(LanPeer? peer) async {
    if (peer == null || _sending) {
      return;
    }
    setState(() => _sending = true);
    try {
      await widget.service.sendText(peer, _textController.text);
      _textController.clear();
      _showSnack('文本已发送');
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _sendFile(LanPeer? peer) async {
    if (peer == null || _sending) {
      return;
    }
    final FilePickerResult? result = await FilePicker.pickFiles();
    final String? path = result?.files.single.path;
    if (path == null) {
      return;
    }
    setState(() => _sending = true);
    try {
      await widget.service.sendFile(peer, File(path));
      _showSnack('文件已发送');
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    _showSnack('已复制文本');
  }

  Future<void> _addManualPeer() async {
    final String? value = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => const _ManualPeerDialog(),
    );
    if (value == null || value.trim().isEmpty) {
      return;
    }
    try {
      final LanPeer peer = await widget.service.addManualPeer(value);
      setState(() => _selectedPeerId = peer.id);
      _showSnack('已添加 ${peer.name}');
    } catch (error) {
      _showSnack(error.toString());
    }
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.service});

  final LanTransferService service;

  @override
  Widget build(BuildContext context) {
    final bool running = service.running;
    return _LanSurface(
      child: Row(
        children: <Widget>[
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: running
                  ? AppTheme.accentDim(context)
                  : AppTheme.elevated(context),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              running ? Icons.lan_rounded : Icons.portable_wifi_off_rounded,
              color: running
                  ? AppTheme.accent(context)
                  : AppTheme.text3(context),
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  running ? '局域网互传已开启' : '局域网互传未开启',
                  style: TextStyle(
                    color: AppTheme.text1(context),
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  running
                      ? '${service.deviceName} · 端口 ${service.port}'
                      : service.error ?? '正在启动本地接收服务',
                  style: TextStyle(
                    color: AppTheme.text3(context),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (service.starting)
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }
}

class _PeerPanel extends StatelessWidget {
  const _PeerPanel({
    required this.peers,
    required this.selectedPeerId,
    required this.onSelect,
    required this.onRefresh,
    required this.onAddManual,
    required this.fillAvailableHeight,
  });

  final List<LanPeer> peers;
  final String? selectedPeerId;
  final ValueChanged<LanPeer> onSelect;
  final VoidCallback onRefresh;
  final VoidCallback onAddManual;
  final bool fillAvailableHeight;

  @override
  Widget build(BuildContext context) {
    return _LanSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '设备',
                  style: TextStyle(
                    color: AppTheme.text1(context),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh_rounded, size: 18),
              ),
              IconButton(
                tooltip: '手动添加',
                onPressed: onAddManual,
                icon: const Icon(Icons.add_link_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (peers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Column(
                children: <Widget>[
                  Icon(
                    Icons.devices_other_rounded,
                    color: AppTheme.text3(context),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '未发现设备',
                    style: TextStyle(
                      color: AppTheme.text2(context),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            )
          else
            _PanelListFrame(
              fillAvailableHeight: fillAvailableHeight,
              maxHeight: 260,
              child: ListView.separated(
                shrinkWrap: !fillAvailableHeight,
                physics: fillAvailableHeight
                    ? null
                    : const NeverScrollableScrollPhysics(),
                itemBuilder: (BuildContext context, int index) {
                  final LanPeer peer = peers[index];
                  final bool selected =
                      peer.id == selectedPeerId ||
                      selectedPeerId == null && index == 0;
                  return Material(
                    color: selected
                        ? AppTheme.accentDim(context)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => onSelect(peer),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Row(
                          children: <Widget>[
                            Icon(
                              Icons.computer_rounded,
                              color: selected
                                  ? AppTheme.accent(context)
                                  : AppTheme.text3(context),
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    peer.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: AppTheme.text1(context),
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '${peer.address}:${peer.port}',
                                    style: TextStyle(
                                      color: AppTheme.text3(context),
                                      fontSize: 11,
                                      fontFamily: 'Consolas',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemCount: peers.length,
              ),
            ),
        ],
      ),
    );
  }
}

class _SendPanel extends StatelessWidget {
  const _SendPanel({
    required this.controller,
    required this.peer,
    required this.sending,
    required this.onSendText,
    required this.onSendFile,
  });

  final TextEditingController controller;
  final LanPeer? peer;
  final bool sending;
  final VoidCallback onSendText;
  final VoidCallback onSendFile;

  @override
  Widget build(BuildContext context) {
    final bool enabled = peer != null && !sending;
    return _LanSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  peer == null ? '发送' : '发送到 ${peer!.name}',
                  style: TextStyle(
                    color: AppTheme.text1(context),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (sending)
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            minLines: 3,
            maxLines: 6,
            enabled: enabled,
            decoration: const InputDecoration(
              hintText: '输入要发送的文本',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              FilledButton.icon(
                onPressed: enabled ? onSendText : null,
                icon: const Icon(Icons.send_rounded, size: 18),
                label: const Text('发送文本'),
              ),
              OutlinedButton.icon(
                onPressed: enabled ? onSendFile : null,
                icon: const Icon(Icons.attach_file_rounded, size: 18),
                label: const Text('发送文件'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HistoryPanel extends StatelessWidget {
  const _HistoryPanel({
    required this.records,
    required this.onClear,
    required this.onCopyText,
    required this.fillAvailableHeight,
  });

  final List<LanTransferRecord> records;
  final VoidCallback onClear;
  final ValueChanged<String> onCopyText;
  final bool fillAvailableHeight;

  @override
  Widget build(BuildContext context) {
    return _LanSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '记录',
                  style: TextStyle(
                    color: AppTheme.text1(context),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: records.isEmpty ? null : onClear,
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('清空'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (records.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 34),
              child: Text(
                '暂无互传记录',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.text3(context)),
              ),
            )
          else
            _PanelListFrame(
              fillAvailableHeight: fillAvailableHeight,
              maxHeight: 420,
              child: ListView.separated(
                shrinkWrap: !fillAvailableHeight,
                physics: fillAvailableHeight
                    ? null
                    : const NeverScrollableScrollPhysics(),
                itemBuilder: (BuildContext context, int index) {
                  return _HistoryItem(
                    record: records[index],
                    onCopyText: onCopyText,
                  );
                },
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemCount: records.length,
              ),
            ),
        ],
      ),
    );
  }
}

class _HistoryItem extends StatelessWidget {
  const _HistoryItem({required this.record, required this.onCopyText});

  final LanTransferRecord record;
  final ValueChanged<String> onCopyText;

  @override
  Widget build(BuildContext context) {
    final bool incoming = record.direction == LanTransferDirection.incoming;
    final bool failed = record.status == LanTransferStatus.failed;
    final String title = record.kind == LanTransferKind.text
        ? (record.text ?? '')
        : record.fileName ?? '文件';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.elevated(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border(context)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            record.kind == LanTransferKind.text
                ? Icons.notes_rounded
                : Icons.insert_drive_file_rounded,
            color: failed
                ? AppColors.red
                : incoming
                ? AppTheme.accent(context)
                : AppTheme.text2(context),
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title.isEmpty ? '空文本' : title,
                  maxLines: record.kind == LanTransferKind.text ? 3 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppTheme.text1(context),
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${incoming ? '来自' : '发往'} ${record.peerName} · ${_timeText(record.createdAt)}',
                  style: TextStyle(
                    color: AppTheme.text3(context),
                    fontSize: 11,
                  ),
                ),
                if (record.kind == LanTransferKind.file) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    '${_sizeText(record.fileSize)} · ${record.filePath ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.text3(context),
                      fontFamily: 'Consolas',
                      fontSize: 11,
                    ),
                  ),
                ],
                if (failed && record.error != null) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    record.error!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.red, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
          if (record.kind == LanTransferKind.text && record.text != null)
            IconButton(
              tooltip: '复制',
              onPressed: () => onCopyText(record.text!),
              icon: const Icon(Icons.content_copy_rounded, size: 17),
            ),
        ],
      ),
    );
  }
}

class _LanSurface extends StatelessWidget {
  const _LanSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
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
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}

class _ManualPeerDialog extends StatefulWidget {
  const _ManualPeerDialog();

  @override
  State<_ManualPeerDialog> createState() => _ManualPeerDialogState();
}

class _ManualPeerDialogState extends State<_ManualPeerDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('手动添加设备'),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '地址',
            hintText: '192.168.1.23:45657',
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('添加')),
      ],
    );
  }

  void _submit() {
    Navigator.of(context).pop(_controller.text.trim());
  }
}

class _PanelListFrame extends StatelessWidget {
  const _PanelListFrame({
    required this.fillAvailableHeight,
    required this.maxHeight,
    required this.child,
  });

  final bool fillAvailableHeight;
  final double maxHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (fillAvailableHeight) {
      return Expanded(child: child);
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: child,
    );
  }
}

String _timeText(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}';
}

String _sizeText(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  final double kb = bytes / 1024;
  if (kb < 1024) {
    return '${kb.toStringAsFixed(1)} KB';
  }
  final double mb = kb / 1024;
  if (mb < 1024) {
    return '${mb.toStringAsFixed(1)} MB';
  }
  return '${(mb / 1024).toStringAsFixed(1)} GB';
}
