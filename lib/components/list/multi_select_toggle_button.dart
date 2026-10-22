import 'package:flutter/material.dart';

class MultiSelectToggleButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;

  const MultiSelectToggleButton({
    super.key,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      icon: Icon(enabled ? Icons.checklist : Icons.checklist_rtl),
      onPressed: onTap,
    );
  }
}
