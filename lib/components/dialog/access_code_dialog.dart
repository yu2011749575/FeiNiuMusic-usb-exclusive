import 'package:flutter/material.dart';

import '../../app/services/feiniu/access_code_service.dart';
import '../../app/state/settings_fn_state.dart';

/// 安全码输入对话框
///
/// 登录时服务器返回 401 需要安全码时弹出。用户输入后调用
/// [AccessCodeService.verify] 校验：
/// - 有效 → 存储安全码并 `pop(code)`；
/// - 无效（401/403/429）→ 内联提示「访问码错误」，可重输；
/// - 网络异常 → 内联提示「网络异常，请稍后重试」；
/// - 取消 → `pop(null)`，调用方中止登录。
class AccessCodeDialog extends StatefulWidget {
  /// 服务器 baseUrl，用于拼接 `/access_code_verify`
  final String baseUrl;

  /// 当前连接是否为中继模式（决定验证请求是否携带 `Cookie: mode=relay`）
  final bool isRelay;

  const AccessCodeDialog({super.key, required this.baseUrl, this.isRelay = false});

  static Future<String?> show(
    BuildContext context, {
    required String baseUrl,
    bool isRelay = false,
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AccessCodeDialog(baseUrl: baseUrl, isRelay: isRelay),
    );
  }

  @override
  State<AccessCodeDialog> createState() => _AccessCodeDialogState();
}

class _AccessCodeDialogState extends State<AccessCodeDialog> {
  final _controller = TextEditingController();
  bool _obscure = true;
  bool _verifying = false;
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _controller.text.trim();
    if (code.isEmpty) {
      setState(() => _errorText = '请输入安全码');
      return;
    }
    setState(() {
      _verifying = true;
      _errorText = null;
    });

    try {
      final ok = await AccessCodeService.instance.verify(
        widget.baseUrl,
        code,
        isRelay: widget.isRelay,
      );
      if (!mounted) return;
      if (ok) {
        await AppFnConnectionSettings.setAccessCode(code);
        if (!mounted) return;
        Navigator.of(context).pop(code);
      } else {
        setState(() => _errorText = '访问码错误');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorText = '网络异常，请稍后重试');
    } finally {
      if (mounted) {
        setState(() => _verifying = false);
      }
    }
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
      title: const Text('输入安全码'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '该服务器开启了访问码保护，请输入访问码以继续',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: _obscure,
            enabled: !_verifying,
            onSubmitted: (_) => _verifying ? null : _submit(),
            decoration: InputDecoration(
              hintText: '访问码',
              prefixIcon: const Icon(Icons.key_rounded),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
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
          onPressed: _verifying ? null : () => Navigator.of(context).pop(null),
          child: const Text('取消'),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _verifying ? null : _submit,
          style: FilledButton.styleFrom(
            minimumSize: const Size(72, 40),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          child: _verifying
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('确定'),
        ),
      ],
    );
  }
}
