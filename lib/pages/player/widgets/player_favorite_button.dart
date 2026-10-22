import 'package:flutter/material.dart';

import '../../../app/services/feiniu/favorite_service.dart';
import '../../../app/state/song_state.dart';
import '../../../components/feedback/app_toast.dart';

class PlayerFavoriteButton extends StatefulWidget {
  final SongEntity? song;
  final double size;

  const PlayerFavoriteButton({super.key, required this.song, this.size = 24});

  @override
  State<PlayerFavoriteButton> createState() => _PlayerFavoriteButtonState();
}

class _PlayerFavoriteButtonState extends State<PlayerFavoriteButton> {
  final FeiNiuFavoriteService _favoriteService = FeiNiuFavoriteService.instance;
  bool _isFavorite = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadFavoriteState();
  }

  @override
  void didUpdateWidget(covariant PlayerFavoriteButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song?.id != widget.song?.id) {
      _loadFavoriteState();
    }
  }

  Future<void> _loadFavoriteState() async {
    final song = widget.song;
    if (song == null) {
      if (mounted) {
        setState(() {
          _isFavorite = false;
          _loading = false;
        });
      }
      return;
    }
    setState(() => _loading = true);
    try {
      final isFavorite = await _favoriteService.isFavorite(song.id);
      if (!mounted || widget.song?.id != song.id) return;
      setState(() {
        _isFavorite = isFavorite;
        _loading = false;
      });
    } catch (_) {
      if (mounted && widget.song?.id == song.id) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _toggleFavorite() async {
    final song = widget.song;
    if (_loading || song == null) return;
    setState(() => _loading = true);
    try {
      if (_isFavorite) {
        await _favoriteService.unfavorite(song.id);
        if (!mounted || widget.song?.id != song.id) return;
        setState(() {
          _isFavorite = false;
          _loading = false;
        });
        AppToast.show(context, '已取消收藏');
      } else {
        await _favoriteService.favorite(song.id);
        if (!mounted || widget.song?.id != song.id) return;
        setState(() {
          _isFavorite = true;
          _loading = false;
        });
        AppToast.show(context, '已收藏');
      }
    } catch (_) {
      if (!mounted || widget.song?.id != song.id) return;
      setState(() => _loading = false);
      AppToast.show(context, '操作失败', type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      key: const ValueKey('player-favorite-button'),
      tooltip: _isFavorite ? '取消收藏' : '收藏',
      visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      icon: Icon(
        _isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        color: _isFavorite
            ? scheme.error
            : scheme.onSurface.withValues(alpha: 0.72),
        size: widget.size,
      ),
      onPressed: widget.song == null || _loading ? null : _toggleFavorite,
    );
  }
}
