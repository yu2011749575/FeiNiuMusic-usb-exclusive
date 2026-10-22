import 'package:flutter/material.dart';

/// 「加载更多」数量输入对话框
///
/// 用户输入要加载到的总数量，校验通过后 `pop(value)`；取消 `pop(null)`。
/// - 非整数 → 内联提示「请输入有效的数量」
/// - 小于当前已加载 → 内联提示「不能少于当前已加载 N 首」
/// - 大于总数 → 内联提示「最多加载 N 首」
///
/// 样式沿用 AccessCodeDialog（圆角 24 的 AlertDialog + TextField + 取消/确认）。
class LoadMoreCountDialog extends StatefulWidget {
  /// 当前已加载数量
  final int currentCount;

  /// 服务端总数（允许的最大值）
  final int maxTotal;

  /// 对话框标题
  final String title;

  const LoadMoreCountDialog({
    super.key,
    required this.currentCount,
    required this.maxTotal,
    this.title = '加载更多',
  });

  static Future<int?> show(
    BuildContext context, {
    required int currentCount,
    required int maxTotal,
    String title = '加载更多',
  }) {
    return showDialog<int>(
      context: context,
      barrierDismissible: true,
      builder: (_) => LoadMoreCountDialog(
        currentCount: currentCount,
        maxTotal: maxTotal,
        title: title,
      ),
    );
  }

  @override
  State<LoadMoreCountDialog> createState() => _LoadMoreCountDialogState();
}

class _LoadMoreCountDialogState extends State<LoadMoreCountDialog> {
  final _controller = TextEditingController();
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.currentCount.toString();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _errorText = '请输入有效的数量');
      return;
    }
    final value = int.tryParse(text);
    if (value == null) {
      setState(() => _errorText = '请输入有效的数量');
      return;
    }
    if (value < widget.currentCount) {
      setState(
        () => _errorText = '不能少于当前已加载 ${widget.currentCount} 首',
      );
      return;
    }
    if (value > widget.maxTotal) {
      setState(() => _errorText = '最多加载 ${widget.maxTotal} 首');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final backgroundColor =
        theme.dialogTheme.backgroundColor ?? theme.colorScheme.surface;

    return AlertDialog(
      backgroundColor: backgroundColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '当前已加载 ${widget.currentCount} 首，共 ${widget.maxTotal} 首。'
            '输入要加载的总数量（按每页向上取整）。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: '数量',
              suffixText: '首',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              errorText: _errorText,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('取消'),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(
            minimumSize: const Size(72, 40),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
