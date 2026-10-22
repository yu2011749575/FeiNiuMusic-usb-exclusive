import 'package:flutter/material.dart';

import 'multi_select_toggle_button.dart';
import 'playback_mode_button.dart';
import 'select_all_button.dart';
import 'sort_action_button.dart';

class MediaListHeader extends StatelessWidget {
  final bool multiSelect;
  final bool isAllSelected;
  final int selectedCount;
  final int totalCount;
  final int playbackCount;
  final bool isSequentialPlay;
  final VoidCallback onToggleSelectAll;
  final VoidCallback onPlay;
  final VoidCallback onConfigurePlay;
  final VoidCallback onTogglePlayMode;
  final VoidCallback onSort;
  final VoidCallback onToggleMultiSelect;

  const MediaListHeader({
    super.key,
    required this.multiSelect,
    required this.isAllSelected,
    required this.selectedCount,
    required this.totalCount,
    required this.playbackCount,
    required this.isSequentialPlay,
    required this.onToggleSelectAll,
    required this.onPlay,
    required this.onConfigurePlay,
    required this.onTogglePlayMode,
    required this.onSort,
    required this.onToggleMultiSelect,
  });

  @override
  Widget build(BuildContext context) {
    final leading = multiSelect
        ? SelectAllButton(
            isAllSelected: isAllSelected,
            selectedCount: selectedCount,
            totalCount: totalCount,
            onTap: onToggleSelectAll,
          )
        : PlaybackModeButton(
            isSequential: isSequentialPlay,
            count: playbackCount,
            onPlay: onPlay,
            onDoubleTap: onConfigurePlay,
            onToggleMode: onTogglePlayMode,
          );
    final trailing = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SortActionButton(onTap: onSort),
        MultiSelectToggleButton(
          enabled: multiSelect,
          onTap: onToggleMultiSelect,
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
      child: Row(
        children: [
          Expanded(child: leading),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
  }
}
