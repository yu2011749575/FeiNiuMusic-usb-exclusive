import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feiniu_music/pages/player/widgets/player_favorite_button.dart';

void main() {
  testWidgets('no song disables the favorite action', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PlayerFavoriteButton(song: null))),
    );
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('player-favorite-button')),
    );
    expect(button.onPressed, isNull);
    expect(button.tooltip, '收藏');
    expect(tester.takeException(), isNull);
  });
}
