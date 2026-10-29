// Renders App Store screenshots (6.9" iPhone, 1320 x 2868) of the real app
// screens with the broadcasts that are live on the server. Not part of the
// normal test run:
//   flutter test screenshot_tool/store_screenshots_test.dart --dart-define=FLUTTER_ROOT=<flutter sdk>
import 'dart:io';
import 'dart:ui' as ui;

import 'package:farmradio/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const flutterRoot = String.fromEnvironment('FLUTTER_ROOT');
const outDir = 'store/screenshots';
const logical = Size(440, 956);
const dpr = 3.0;

// The broadcasts on api.chandus7.in on 29 October 2026.
const songs = [
  Song(id: 34, title: 'Angrau_Audio1.mpeg', fileUrl: 'https://api.chandus7.in/media/farmradio_ios/Angrau_Audio1_mpeg.mp3', order: 0),
  Song(id: 40, title: 'Angrau_Audio2', fileUrl: 'https://api.chandus7.in/media/farmradio_ios/Angrau_Audio2_mpeg.mp3', order: 1),
  Song(id: 36, title: 'Angrau_Audio3.mpeg', fileUrl: 'https://api.chandus7.in/media/farmradio_ios/Angrau_Audio3_mpeg.mp3', order: 2),
  Song(id: 41, title: 'Angrau_Audio4', fileUrl: 'https://api.chandus7.in/media/farmradio_ios/Angrau_Audio4_ogg.m4a', order: 3),
];

class FakePaths extends PathProviderPlatform {
  final String dir;
  FakePaths(this.dir);
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
  @override
  Future<String?> getApplicationCachePath() async => dir;
}

Future<void> loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
  }
  await loader.load();
}

final _boundary = GlobalKey();

Widget frame(Widget home) {
  return RepaintBoundary(
    key: _boundary,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      builder: (context, child) => Stack(
        children: [
          MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: const EdgeInsets.only(top: 62, bottom: 34),
              viewPadding: const EdgeInsets.only(top: 62, bottom: 34),
            ),
            child: child!,
          ),
          const Positioned(top: 0, left: 0, right: 0, child: _StatusBar()),
        ],
      ),
      home: home,
    ),
  );
}

class _StatusBar extends StatelessWidget {
  const _StatusBar();
  static const color = Colors.white;
  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        height: 54,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(44, 18, 32, 0),
          child: DefaultTextStyle(
            style: TextStyle(fontFamily: 'Roboto', fontSize: 17, fontWeight: FontWeight.w600, color: color),
            child: Row(
              children: [
                const Text('9:41'),
                const Spacer(),
                Icon(Icons.signal_cellular_alt, size: 19, color: color),
                const SizedBox(width: 4),
                Icon(Icons.wifi, size: 19, color: color),
                const SizedBox(width: 4),
                Icon(Icons.battery_full, size: 22, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> shoot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 600));
  await tester.runAsync(() async {
    final boundary = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: dpr);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(outDir).createSync(recursive: true);
    File('$outDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<void> precache(WidgetTester tester) async {
  await tester.runAsync(() async {
    final ctx = tester.element(find.byType(Scaffold).first);
    for (final a in [
      'assets/images/farm1.PNG',
      'assets/images/farm2.PNG',
      'assets/images/farm3.png',
      'assets/images/farm4.PNG',
      'assets/images/angrauicon.png',
    ]) {
      await precacheImage(AssetImage(a), ctx);
    }
    await Future.delayed(const Duration(milliseconds: 300));
  });
  await tester.pump();
}

void main() {
  setUpAll(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    // flutter_test paints shadows as solid blocks unless this is turned off.
    debugDisableShadows = false;
    final fonts = '$flutterRoot/bin/cache/artifacts/material_fonts';
    await loadFont('Roboto', [
      '$fonts/roboto-regular.ttf',
      '$fonts/roboto-medium.ttf',
      '$fonts/roboto-bold.ttf',
      '$fonts/roboto-black.ttf',
    ]);
    await loadFont('MaterialIcons', ['$fonts/materialicons-regular.otf']);
    final docs = Directory.systemTemp.createTempSync('farmradio_docs');
    final audios = Directory('${docs.path}/audios')..createSync();
    // Two broadcasts saved for offline listening.
    for (final s in [songs[0], songs[2]]) {
      File('${audios.path}/${Uri.parse(s.fileUrl).pathSegments.last}')
          .writeAsBytesSync(List.filled(s.id == 34 ? 920541 : 5648973, 0));
    }
    PathProviderPlatform.instance = FakePaths(docs.path);
    allSongs = List.of(songs);
  });

  Future<void> setSize(WidgetTester tester) async {
    tester.view.physicalSize = logical * dpr;
    tester.view.devicePixelRatio = dpr;
  }

  void nowPlaying(Song? s) {
    final svc = AudioPlayerService.instance;
    svc.queue = List.of(songs);
    svc.currentSong.value = s;
  }

  testWidgets('home, downloads, settings', (tester) async {
    await setSize(tester);
    nowPlaying(songs[1]);
    await tester.pumpWidget(frame(const MainShell(songs: songs)));
    await precache(tester);
    await shoot(tester, '1_home');

    await tester.tap(find.text('Downloads'));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    await shoot(tester, '3_downloads');

    await tester.tap(find.text('Settings'));
    await tester.pump(const Duration(milliseconds: 300));
    await shoot(tester, '4_settings');
  });

  testWidgets('player', (tester) async {
    await setSize(tester);
    nowPlaying(songs[2]);
    await tester.pumpWidget(frame(const PlayerPage()));
    await precache(tester);
    await shoot(tester, '2_player');
  });

  testWidgets('help', (tester) async {
    await setSize(tester);
    nowPlaying(null);
    await tester.pumpWidget(frame(const HelpPage()));
    await tester.pump();
    await shoot(tester, '5_help');
  });
}
