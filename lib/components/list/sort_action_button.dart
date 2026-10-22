import 'package:flutter/material.dart';

class SortActionButton extends StatelessWidget {
  final VoidCallback onTap;

  const SortActionButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      icon: const Icon(Icons.sort),
      onPressed: onTap,
    );
  }
}
