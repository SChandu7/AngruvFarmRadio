import 'package:farmradio/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('broadcast titles drop the file extension and underscores', () {
    const s = Song(id: 1, title: 'Angrau_Audio1.mpeg', fileUrl: 'https://x/a.mp3');
    expect(s.displayTitle, 'Angrau Audio1');
    const t = Song(id: 2, title: 'Paddy advisory', fileUrl: 'https://x/b.mp3');
    expect(t.displayTitle, 'Paddy advisory');
  });

  test('song JSON round trip', () {
    final s = Song.fromJson({'id': 3, 'title': 'A', 'file_url': 'https://x/c.m4a', 'order': 2});
    expect(Song.fromJson(s.toJson()).toJson(), s.toJson());
  });

  testWidgets('help page lists how to use the app', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: AppTheme.theme, home: const HelpPage()));
    expect(find.text('Listen without internet'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('Helpline'), 200);
    expect(find.textContaining('Helpline'), findsOneWidget);
  });
}
