import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

// ============================================================
// THEME
// ============================================================
class AppTheme {
  static const Color primary = Color(0xFF2E7D32);
  static const Color primaryLight = Color(0xFF4CAF50);
  static const Color primaryDark = Color(0xFF1B5E20);
  static const Color earth = Color(0xFF6D4C41);
  static const Color amber = Color(0xFFFF8F00);
  static const Color cream = Color(0xFFF5F1E8);
  static const Color textDark = Color(0xFF1A1A1A);
  static const Color textMid = Color(0xFF555555);
  static const Color textLight = Color(0xFF888888);

  static ThemeData get theme => ThemeData(
    brightness: Brightness.light,
    primaryColor: primary,
    scaffoldBackgroundColor: cream,
    colorScheme: const ColorScheme.light(primary: primary, secondary: amber),
    fontFamily: 'Roboto',
    appBarTheme: const AppBarTheme(
      backgroundColor: primary,
      foregroundColor: Colors.white,
      iconTheme: IconThemeData(color: Colors.white),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}

// ============================================================
// LINKS
// ============================================================
class AppLinks {
  static const String version = '2.0.0';
  static const String privacy =
      'https://api.chandus7.in/angraudaattc/farmradio/privacy/';
  static const String support =
      'https://api.chandus7.in/angraudaattc/farmradio/support/';
  static const String website = 'https://angrau.ac.in';
  static const String helpline = '18004250430';
  static const String helplineLabel = '1800 425 0430';
  static const String email = 'dev@chandus7.in';
}

void showSnack(BuildContext context, String msg, Color bg) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(msg),
      backgroundColor: bg,
      behavior: SnackBarBehavior.floating,
    ),
  );
}

Future<void> openWebPage(BuildContext context, String url) async {
  bool ok = false;
  try {
    ok = await launchUrl(Uri.parse(url), mode: LaunchMode.inAppBrowserView);
  } catch (_) {}
  if (!ok && context.mounted) {
    showSnack(context, "Could not open $url", Colors.grey.shade800);
  }
}

/// Opens the dialer; on devices that cannot call (iPad, iPod) shows the number.
Future<void> callHelpline(BuildContext context) async {
  final uri = Uri(scheme: 'tel', path: AppLinks.helpline);
  bool ok = false;
  try {
    ok = await canLaunchUrl(uri) && await launchUrl(uri);
  } catch (_) {}
  if (ok || !context.mounted) return;
  showDialog(
    context: context,
    builder: (_) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text("ANGRAU Helpline"),
      content: const Text(
        "Toll-free: ${AppLinks.helplineLabel}\n\nCall this number from any phone for advice about crops.",
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("OK"),
        ),
      ],
    ),
  );
}

// ============================================================
// SONG MODEL
// ============================================================
class Song {
  final int id;
  final String title;
  final String fileUrl;
  final int order;

  const Song({
    required this.id,
    required this.title,
    required this.fileUrl,
    this.order = 0,
  });

  /// Title without the file extension and underscores ("Angrau_Audio1.mpeg"
  /// -> "Angrau Audio1").
  String get displayTitle => title
      .replaceAll(RegExp(r'\.[A-Za-z0-9]{2,4}$'), '')
      .replaceAll('_', ' ')
      .trim();

  factory Song.fromJson(Map<String, dynamic> json) => Song(
    id: json['id'],
    title: json['title'],
    fileUrl: json['file_url'],
    order: json['order'] ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'file_url': fileUrl,
    'order': order,
  };
}

// ============================================================
// GLOBAL
// ============================================================
List<Song> allSongs = [];

/// Bumped whenever a broadcast is saved or removed, so every screen that
/// shows download state refreshes.
final ValueNotifier<int> downloadsChanged = ValueNotifier(0);

// ============================================================
// AUDIO PLAYER SERVICE (singleton)
// ============================================================
/// One playlist on one player: next/previous, shuffle, repeat and moving on to
/// the next broadcast all happen in just_audio, and just_audio_background shows
/// the broadcast on the lock screen, in Control Center and in the Android
/// notification.
class AudioPlayerService {
  static final AudioPlayerService _inst = AudioPlayerService._();
  static AudioPlayerService get instance => _inst;

  AudioPlayerService._() {
    player.currentIndexStream.listen((i) {
      if (i != null && i >= 0 && i < queue.length) currentSong.value = queue[i];
    });
    player.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace _) {
        debugPrint('Audio error: $e');
        playError.value =
            "Could not play this broadcast. Check your internet connection.";
      },
    );
  }

  final AudioPlayer player = AudioPlayer();
  final ValueNotifier<Song?> currentSong = ValueNotifier(null);
  final ValueNotifier<String?> playError = ValueNotifier(null);
  List<Song> queue = [];

  int get currentIndex => player.currentIndex ?? 0;

  Future<void> playFromQueue(List<Song> songs, int index) async {
    final sameQueue =
        queue.length == songs.length &&
        Iterable.generate(songs.length).every(
          (i) =>
              queue[i].id == songs[i].id &&
              queue[i].fileUrl == songs[i].fileUrl,
        );
    if (sameQueue &&
        player.currentIndex == index &&
        player.audioSource != null) {
      if (!player.playing) player.play();
      return;
    }
    queue = List.of(songs);
    currentSong.value = queue[index];
    playError.value = null;
    try {
      final sources = <AudioSource>[for (final s in queue) await _source(s)];
      await player.setAudioSources(sources, initialIndex: index);
      player.play();
    } catch (e) {
      debugPrint('Audio error: $e');
      playError.value =
          "Could not play this broadcast. Check your internet connection.";
    }
  }

  Future<AudioSource> _source(Song s) async {
    final tag = MediaItem(
      id: '${s.id}:${s.fileUrl}',
      title: s.displayTitle,
      artist: 'ANGRAU Farm Advisory',
      album: 'ANGRAU Farm Radio',
    );
    if (s.fileUrl.startsWith('/')) return AudioSource.file(s.fileUrl, tag: tag);
    final local = await AudioCacheService.getLocalPath(s.fileUrl);
    if (File(local).existsSync()) return AudioSource.file(local, tag: tag);
    return AudioSource.uri(Uri.parse(s.fileUrl), tag: tag);
  }

  Future<void> next() => player.seekToNext();

  Future<void> previous() async {
    // Like most players: go back to the start first, then to the previous one.
    if (player.position > const Duration(seconds: 3) || !player.hasPrevious) {
      await player.seek(Duration.zero);
    } else {
      await player.seekToPrevious();
    }
  }

  Future<void> toggleShuffle() async {
    final on = !player.shuffleModeEnabled;
    if (on) await player.shuffle();
    await player.setShuffleModeEnabled(on);
  }

  Future<void> cycleRepeat() async {
    const order = [LoopMode.off, LoopMode.all, LoopMode.one];
    await player.setLoopMode(
      order[(order.indexOf(player.loopMode) + 1) % order.length],
    );
  }

  void seekBy(Duration offset) {
    final pos = player.position;
    final total = player.duration ?? Duration.zero;
    Duration target = pos + offset;
    if (target < Duration.zero) target = Duration.zero;
    if (target > total) target = total;
    player.seek(target);
  }
}

// ============================================================
// API SERVICE
// ============================================================
class ApiException implements Exception {
  final String message;
  final bool sessionExpired;
  const ApiException(this.message, {this.sessionExpired = false});
  @override
  String toString() => message;
}

/// Text for an error from an API call, for a snackbar.
String errorText(Object e) => e is ApiException
    ? e.message
    : "Check your internet connection and try again.";

class ApiService {
  // Same broadcasts as /api/farmradio/, with audio every phone can play and
  // admin actions that need a login checked by the server.
  static const String baseUrl =
      "https://api.chandus7.in/angraudaattc/farmradio";

  static Future<Map<String, String>> _headers({bool json = false}) async {
    final token = await AuthPrefs.token();
    return {
      if (token != null) 'Authorization': 'Bearer $token',
      if (json) 'Content-Type': 'application/json',
    };
  }

  static void _check(int status, String body) {
    if (status >= 200 && status < 300) return;
    String msg = "Server error ($status). Please try again.";
    try {
      final err = jsonDecode(body)['error'];
      if (err is String && err.isNotEmpty) msg = err;
    } catch (_) {}
    throw ApiException(msg, sessionExpired: status == 401);
  }

  static Future<List<Song>> fetchSongs() async {
    final res = await http
        .get(Uri.parse("$baseUrl/songs/"), headers: await _headers())
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 401) {
      // Token no longer valid: sign out and load the public list.
      await AuthPrefs.logout();
      return fetchSongs();
    }
    _check(res.statusCode, res.body);
    final List data = jsonDecode(utf8.decode(res.bodyBytes));
    return data.map((e) => Song.fromJson(e)).toList();
  }

  static Future<void> login(String username, String password) async {
    final res = await http
        .post(
          Uri.parse("$baseUrl/login/"),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'username': username, 'password': password}),
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 401) {
      throw const ApiException("Invalid username or password.");
    }
    _check(res.statusCode, res.body);
    final data = jsonDecode(res.body);
    await AuthPrefs.save(data['token'], data['name'] ?? username);
  }

  static Future<void> deleteSong(int id) async {
    final res = await http
        .delete(Uri.parse("$baseUrl/songs/$id/"), headers: await _headers())
        .timeout(const Duration(seconds: 20));
    _check(res.statusCode, res.body);
  }

  static Future<void> uploadSong(String path) async {
    final req = http.MultipartRequest(
      "POST",
      Uri.parse("$baseUrl/songs/upload/"),
    );
    req.headers.addAll(await _headers());
    req.files.add(await http.MultipartFile.fromPath("file", path));
    final res = await req.send().timeout(const Duration(minutes: 10));
    _check(res.statusCode, await res.stream.bytesToString());
  }

  static Future<void> reorderSongs(List<Song> songs) async {
    final body = jsonEncode(
      songs
          .asMap()
          .entries
          .map((e) => {'id': e.value.id, 'order': e.key})
          .toList(),
    );
    final res = await http
        .patch(
          Uri.parse("$baseUrl/songs/reorder/"),
          headers: await _headers(json: true),
          body: body,
        )
        .timeout(const Duration(seconds: 20));
    _check(res.statusCode, res.body);
  }
}

// ============================================================
// SONG CACHE SERVICE
// ============================================================
class SongCacheService {
  static const String _key = 'cached_songs_v3';

  static Future<void> save(List<Song> songs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(songs.map((s) => s.toJson()).toList()),
    );
  }

  static Future<List<Song>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      final List data = jsonDecode(raw);
      return data.map((e) => Song.fromJson(e)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

// ============================================================
// AUDIO CACHE SERVICE
// ============================================================
class AudioCacheService {
  static Future<Directory> _dir() async {
    // iOS: Library/Caches, which is not backed up to iCloud (Apple's storage
    // rules for content that can be downloaded again). Android: unchanged.
    final d = Platform.isIOS
        ? await getApplicationCacheDirectory()
        : await getApplicationDocumentsDirectory();
    final audio = Directory('${d.path}/audios');
    if (!audio.existsSync()) audio.createSync(recursive: true);
    return audio;
  }

  static Future<String> getLocalPath(String fileUrl) async {
    final name = Uri.parse(fileUrl).pathSegments.last;
    final d = await _dir();
    return '${d.path}/$name';
  }

  static Future<bool> isDownloaded(String fileUrl) async {
    if (fileUrl.startsWith('/')) return File(fileUrl).existsSync();
    final path = await getLocalPath(fileUrl);
    return File(path).existsSync();
  }

  static Future<String> downloadSong(String fileUrl) async {
    final path = await getLocalPath(fileUrl);
    final file = File(path);
    if (file.existsSync()) return path;
    final res = await http
        .get(Uri.parse(fileUrl))
        .timeout(const Duration(minutes: 5));
    if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
      throw const ApiException("Download failed – check connection");
    }
    // Write to .part first so a cut download is never taken as saved.
    final part = File('$path.part');
    await part.writeAsBytes(res.bodyBytes, flush: true);
    await part.rename(path);
    downloadsChanged.value++;
    return path;
  }

  static Future<void> deleteLocal(String fileUrl) async {
    final path = fileUrl.startsWith('/')
        ? fileUrl
        : await getLocalPath(fileUrl);
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
    downloadsChanged.value++;
  }

  static Future<List<File>> _files() async {
    final d = await _dir();
    return d
        .listSync()
        .whereType<File>()
        .where((f) => !f.path.endsWith('.part'))
        .toList();
  }

  static Future<double> totalSizeMB() async {
    double total = 0;
    for (final f in await _files()) {
      total += f.lengthSync();
    }
    return total / (1024 * 1024);
  }

  static Future<List<Song>> localOnlySongs() async {
    final files = await _files();
    return files.asMap().entries.map((e) {
      final name = e.value.path.split('/').last;
      return Song(id: -1 - e.key, title: name, fileUrl: e.value.path);
    }).toList();
  }
}

// ============================================================
// AUTH PREFS
// ============================================================
/// Staff login. The server checks the password and returns a token, which is
/// kept here until logout.
class AuthPrefs {
  static const String _tokenKey = 'farmradio_admin_token';
  static const String _nameKey = 'farmradio_admin_name';

  static Future<void> save(String token, String name) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_tokenKey, token);
    await p.setString(_nameKey, name);
  }

  static Future<String?> token() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_tokenKey);
  }

  static Future<String?> name() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_nameKey);
  }

  static Future<bool> isLoggedIn() async => (await token()) != null;

  static Future<void> logout() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_tokenKey);
    await p.remove(_nameKey);
    await p.remove('is_admin_logged_in'); // left over from v1
  }
}

// ============================================================
// MAIN
// ============================================================
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.farmradio.app.playback',
    androidNotificationChannelName: 'Farm Radio playback',
    androidNotificationOngoing: true,
  );
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.speech());
  runApp(const FarmRadioApp());
}

class FarmRadioApp extends StatelessWidget {
  const FarmRadioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ANGRAU Farm Radio',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      home: const SplashScreen(),
    );
  }
}

// ============================================================
// SPLASH SCREEN
// ============================================================
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  static const _minShow = Duration(seconds: 2);
  String _status = "Initializing...";
  double _timerProgress = 0.0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimerProgress();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTimerProgress() {
    final totalMs = _minShow.inMilliseconds;
    const tickMs = 50;
    int elapsed = 0;
    _timer = Timer.periodic(const Duration(milliseconds: tickMs), (t) {
      elapsed += tickMs;
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _timerProgress = (elapsed / totalMs).clamp(0.0, 1.0));
      if (elapsed >= totalMs) t.cancel();
    });
  }

  Future<void> _load() async {
    http
        .post(
          Uri.parse("https://api.chandus7.in/api/track-visit/"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({"app_name": "Angrau FarmRadio"}),
        )
        .ignore();

    final start = DateTime.now();

    _setStatus("Loading saved broadcasts...");
    List<Song> songs = await SongCacheService.load();
    allSongs = songs;

    try {
      _setStatus("Syncing with server...");
      final fresh = await ApiService.fetchSongs();
      songs = fresh;
      allSongs = fresh;
      await SongCacheService.save(fresh);
      _setStatus("Ready!");
    } catch (_) {
      if (songs.isEmpty) {
        _setStatus("Loading offline files...");
        songs = await AudioCacheService.localOnlySongs();
        allSongs = songs;
      }
      _setStatus(songs.isEmpty ? "No content available" : "Offline mode");
    }

    final elapsed = DateTime.now().difference(start);
    if (elapsed < _minShow) await Future.delayed(_minShow - elapsed);

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => MainShell(songs: songs)),
    );
  }

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 25),

                      Text(
                        "ACHARYA N.G RANGA",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.green.shade800,
                        ),
                      ),
                      Text(
                        "AGRICULTURAL UNIVERSITY",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Colors.green.shade800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        "LAM, GUNTUR, ANDHRA PRADESH",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Colors.green.shade800,
                        ),
                      ),

                      const SizedBox(height: 18),

                      Image.asset(
                        "assets/images/angrauicon.png",
                        width: MediaQuery.of(context).size.width * 0.45,
                        fit: BoxFit.contain,
                      ),

                      const SizedBox(height: 10),
                      Text(
                        "ANGRAU",
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Colors.green.shade800,
                        ),
                      ),

                      const SizedBox(height: 20),

                      Text(
                        "Developed by",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.green.shade800,
                        ),
                      ),

                      const SizedBox(height: 12),

                      Container(
                        width: MediaQuery.of(context).size.width * 0.93,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(15),
                          border: Border.all(
                            color: Colors.green.shade800,
                            width: 2,
                          ),
                        ),
                        child: const Column(
                          children: [
                            Text(
                              "DR. P.B. PRADEEP KUMAR\nSENIOR SCIENTIST & COORDINATOR,\nDAATTC-PADERU, ALLURI SITARAMARAJU DISTRICT\nACHARYA N.G.RANGA AGRICULTURAL UNIVERSITY, GUNTUR, A.P.",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            SizedBox(height: 10),
                          ],
                        ),
                      ),

                      const SizedBox(height: 30),
                    ],
                  ),
                ),
              ),
            ),

            // Bottom progress bar
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    children: [
                      Container(
                        height: 4,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      FractionallySizedBox(
                        widthFactor: _timerProgress,
                        child: Container(
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.blue,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _status,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade500,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// MAIN SHELL (3-tab navigation)
// ============================================================
class MainShell extends StatefulWidget {
  final List<Song> songs;
  const MainShell({super.key, required this.songs});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _tab = 0;
  late List<Song> _songs;
  DateTime? _lastBack;

  @override
  void initState() {
    super.initState();
    _songs = widget.songs;
    AudioPlayerService.instance.playError.addListener(_onPlayError);
  }

  @override
  void dispose() {
    AudioPlayerService.instance.playError.removeListener(_onPlayError);
    super.dispose();
  }

  void _onPlayError() {
    final msg = AudioPlayerService.instance.playError.value;
    if (msg != null && mounted) showSnack(context, msg, Colors.red);
  }

  void _updateSongs(List<Song> updated) {
    setState(() {
      _songs = updated;
      allSongs = updated;
    });
  }

  /// Reloads the broadcast list from the server (pull to refresh, login,
  /// logout). Keeps the current list when offline.
  Future<void> _refresh() async {
    try {
      final fresh = await ApiService.fetchSongs();
      await SongCacheService.save(fresh);
      if (mounted) _updateSongs(fresh);
    } catch (_) {
      if (mounted) {
        showSnack(
          context,
          "Could not refresh. Check your internet connection.",
          Colors.grey.shade800,
        );
      }
    }
  }

  void _openPlayer(Song song) {
    final index = _songs.indexOf(song);
    if (index == -1) return;
    AudioPlayerService.instance.playFromQueue(_songs, index);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PlayerPage()),
    );
  }

  // Android: press back twice to leave the app. iOS has no back button.
  void _onBack(bool didPop, Object? _) {
    if (didPop) return;
    final now = DateTime.now();
    if (_lastBack != null &&
        now.difference(_lastBack!) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _lastBack = now;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Press back again to exit"),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: defaultTargetPlatform != TargetPlatform.android,
      onPopInvokedWithResult: _onBack,
      child: Scaffold(
        body: IndexedStack(
          index: _tab,
          children: [
            HomePage(songs: _songs, onPlay: _openPlayer, onRefresh: _refresh),
            DownloadsPage(songs: _songs, onPlay: _openPlayer),
            SettingsPage(
              onUpdate: () => setState(() {}),
              songs: _songs,
              onSongsUpdated: _updateSongs,
              onRefresh: _refresh,
            ),
          ],
        ),
        // Coloured so the gap around the mini player is not drawn black.
        bottomNavigationBar: ColoredBox(
          color: AppTheme.cream,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MiniPlayer(
                onTap: () {
                  if (AudioPlayerService.instance.currentSong.value != null) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const PlayerPage()),
                    );
                  }
                },
              ),
              BottomNavigationBar(
                currentIndex: _tab,
                onTap: (i) => setState(() => _tab = i),
                selectedItemColor: AppTheme.primary,
                unselectedItemColor: Colors.grey,
                backgroundColor: Colors.white,
                type: BottomNavigationBarType.fixed,
                elevation: 12,
                items: const [
                  BottomNavigationBarItem(
                    icon: Icon(Icons.home_rounded),
                    label: "Home",
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.download_rounded),
                    label: "Downloads",
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.settings_rounded),
                    label: "Settings",
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// MINI PLAYER BAR
// ============================================================
class _MiniPlayer extends StatelessWidget {
  final VoidCallback onTap;
  const _MiniPlayer({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final svc = AudioPlayerService.instance;
    return ValueListenableBuilder<Song?>(
      valueListenable: svc.currentSong,
      builder: (_, song, _) {
        if (song == null) return const SizedBox.shrink();
        return GestureDetector(
          onTap: onTap,
          child: Container(
            height: 62,
            margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: const LinearGradient(
                colors: [AppTheme.primaryDark, AppTheme.primary],
              ),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primary.withValues(alpha: 0.35),
                  blurRadius: 10,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Container(
                  height: 38,
                  width: 38,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.15),
                  ),
                  child: const Icon(
                    Icons.music_note_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.displayTitle,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                      const Text(
                        "ANGRAU Farm Advisory",
                        style: TextStyle(color: Colors.white60, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                StreamBuilder<PlayerState>(
                  stream: svc.player.playerStateStream,
                  builder: (_, snap) {
                    final playing = snap.data?.playing ?? false;
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: playing ? "Pause" : "Play",
                          icon: Icon(
                            playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 28,
                          ),
                          onPressed: () =>
                              playing ? svc.player.pause() : svc.player.play(),
                        ),
                        IconButton(
                          tooltip: "Next",
                          icon: const Icon(
                            Icons.skip_next_rounded,
                            color: Colors.white,
                            size: 24,
                          ),
                          onPressed: svc.next,
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ============================================================
// HOME PAGE
// ============================================================
class HomePage extends StatelessWidget {
  final List<Song> songs;
  final Function(Song) onPlay;
  final Future<void> Function() onRefresh;
  const HomePage({
    super.key,
    required this.songs,
    required this.onPlay,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.cream,
      appBar: AppBar(
        elevation: 0,
        automaticallyImplyLeading: false,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [AppTheme.primaryDark, AppTheme.primary],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        leading: Padding(
          padding: const EdgeInsets.all(8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset(
              "assets/images/angrauicon.png",
              fit: BoxFit.contain,
            ),
          ),
        ),
        centerTitle: true,
        title: const Text(
          "ANGRAU FARM RADIO",
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            onSelected: (value) {
              if (value == 'about') {
                showAboutDialog(
                  context: context,
                  applicationName: 'ANGRAU Farm Radio',
                  applicationVersion: 'Version ${AppLinks.version}',
                  applicationIcon: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.asset(
                      "assets/images/angrauicon.png",
                      height: 48,
                      width: 48,
                    ),
                  ),
                  children: const [
                    Text(
                      'Agricultural advisory audio broadcasts by Acharya N.G. Ranga Agricultural University, Guntur, Andhra Pradesh.',
                    ),
                  ],
                );
              } else if (value == 'help') {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const HelpPage()),
                );
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'about',
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      color: AppTheme.primary,
                      size: 20,
                    ),
                    SizedBox(width: 10),
                    Text("About App"),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'help',
                child: Row(
                  children: [
                    Icon(
                      Icons.help_outline_rounded,
                      color: AppTheme.primary,
                      size: 20,
                    ),
                    SizedBox(width: 10),
                    Text("Help"),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        color: AppTheme.primary,
        onRefresh: onRefresh,
        child: songs.isEmpty
            ? _emptyState()
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 16),
                children: [
                  const SizedBox(height: 14),
                  _header("Featured"),
                  const SizedBox(height: 8),
                  _AutoCarousel(songs: songs, onSelect: onPlay),
                  const SizedBox(height: 20),
                  _header("All Broadcasts (${songs.length})"),
                  const SizedBox(height: 8),
                  ...songs.map(
                    (s) => _SongCard(
                      key: ValueKey('${s.id}:${s.fileUrl}'),
                      song: s,
                      onPlay: onPlay,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
      ),
    );
  }

  Widget _header(String label) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Row(
      children: [
        Container(
          width: 4,
          height: 18,
          decoration: BoxDecoration(
            color: AppTheme.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppTheme.textDark,
          ),
        ),
      ],
    ),
  );

  Widget _emptyState() => ListView(
    physics: const AlwaysScrollableScrollPhysics(),
    children: [
      const SizedBox(height: 120),
      const Icon(Icons.radio, size: 72, color: Colors.grey),
      const SizedBox(height: 16),
      const Text(
        "No broadcasts available",
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 16, color: Colors.grey),
      ),
      const SizedBox(height: 8),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 40),
        child: Text(
          "Check your internet connection and try again",
          style: TextStyle(fontSize: 13, color: Colors.grey),
          textAlign: TextAlign.center,
        ),
      ),
      const SizedBox(height: 20),
      Center(
        child: ElevatedButton.icon(
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text("Try again"),
        ),
      ),
    ],
  );
}

// ============================================================
// SONG CARD (with per-song download button)
// ============================================================
class _SongCard extends StatefulWidget {
  final Song song;
  final Function(Song) onPlay;
  const _SongCard({super.key, required this.song, required this.onPlay});

  @override
  State<_SongCard> createState() => _SongCardState();
}

class _SongCardState extends State<_SongCard> {
  bool _downloaded = false;
  bool _downloading = false;

  String get _title => widget.song.displayTitle;

  @override
  void initState() {
    super.initState();
    _checkDownloaded();
    downloadsChanged.addListener(_checkDownloaded);
  }

  @override
  void dispose() {
    downloadsChanged.removeListener(_checkDownloaded);
    super.dispose();
  }

  Future<void> _checkDownloaded() async {
    final v = await AudioCacheService.isDownloaded(widget.song.fileUrl);
    if (mounted) setState(() => _downloaded = v);
  }

  Future<void> _toggleDownload() async {
    if (_downloaded) {
      await AudioCacheService.deleteLocal(widget.song.fileUrl);
      if (mounted) setState(() => _downloaded = false);
      _snack("Removed from downloads", Colors.grey.shade700);
    } else {
      setState(() => _downloading = true);
      try {
        await AudioCacheService.downloadSong(widget.song.fileUrl);
        if (mounted) {
          setState(() {
            _downloaded = true;
            _downloading = false;
          });
        }
        _snack("'$_title' saved offline", AppTheme.primary);
      } catch (_) {
        if (mounted) setState(() => _downloading = false);
        _snack("Download failed – check connection", Colors.red);
      }
    }
  }

  void _snack(String msg, Color bg) {
    if (!mounted) return;
    showSnack(context, msg, bg);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Song?>(
      valueListenable: AudioPlayerService.instance.currentSong,
      builder: (_, current, _) {
        final active = current?.id == widget.song.id;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: Colors.white,
            border: active
                ? Border.all(color: AppTheme.primary, width: 1.5)
                : null,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: ListTile(
            onTap: () => widget.onPlay(widget.song),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 8,
            ),
            leading: Container(
              height: 50,
              width: 50,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: LinearGradient(
                  colors: active
                      ? [AppTheme.primary, AppTheme.primaryLight]
                      : [const Color(0xFF558B2F), const Color(0xFF8BC34A)],
                ),
              ),
              child: Icon(
                active ? Icons.graphic_eq_rounded : Icons.music_note_rounded,
                color: Colors.white,
                size: 26,
              ),
            ),
            title: Text(
              _title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
                color: active ? AppTheme.primary : AppTheme.textDark,
              ),
            ),
            subtitle: Text(
              active ? "Now Playing" : "ANGRAU Advisory",
              style: TextStyle(
                fontSize: 12,
                color: active ? AppTheme.primary : AppTheme.textLight,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _downloading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppTheme.primary,
                        ),
                      )
                    : IconButton(
                        tooltip: _downloaded
                            ? "Remove download"
                            : "Save for offline listening",
                        icon: Icon(
                          _downloaded
                              ? Icons.download_done_rounded
                              : Icons.download_outlined,
                          color: _downloaded ? AppTheme.primary : Colors.grey,
                          size: 22,
                        ),
                        onPressed: _toggleDownload,
                        splashRadius: 20,
                      ),
                IconButton(
                  tooltip: "Play",
                  icon: Container(
                    height: 34,
                    width: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: active
                          ? AppTheme.primary
                          : AppTheme.primary.withValues(alpha: 0.1),
                    ),
                    child: Icon(
                      Icons.play_arrow_rounded,
                      color: active ? Colors.white : AppTheme.primary,
                      size: 22,
                    ),
                  ),
                  onPressed: () => widget.onPlay(widget.song),
                  splashRadius: 20,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ============================================================
// AUTO CAROUSEL
// ============================================================
class _AutoCarousel extends StatefulWidget {
  final List<Song> songs;
  final Function(Song) onSelect;
  const _AutoCarousel({required this.songs, required this.onSelect});

  @override
  State<_AutoCarousel> createState() => _AutoCarouselState();
}

const List<String> _farmImages = [
  "assets/images/farm1.PNG",
  "assets/images/farm2.PNG",
  "assets/images/farm3.png",
  "assets/images/farm4.PNG",
];

class _AutoCarouselState extends State<_AutoCarousel> {
  late final PageController _ctrl;
  int _idx = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _ctrl = PageController(viewportFraction: 0.82);
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_ctrl.hasClients || widget.songs.isEmpty) return;
      _idx = (_idx + 1) % widget.songs.length;
      _ctrl.animateToPage(
        _idx,
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 185,
      child: PageView.builder(
        controller: _ctrl,
        itemCount: widget.songs.length,
        onPageChanged: (i) => setState(() => _idx = i),
        itemBuilder: (_, i) {
          final song = widget.songs[i];
          final img = _farmImages[i % _farmImages.length];
          final isActive = i == _idx;

          return AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            margin: EdgeInsets.symmetric(
              horizontal: 6,
              vertical: isActive ? 0 : 14,
            ),
            child: GestureDetector(
              onTap: () => widget.onSelect(song),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.asset(img, fit: BoxFit.cover),
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.72),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 14,
                      right: 54,
                      bottom: 14,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.primary.withValues(alpha: 0.85),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              "ADVISORY",
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.2,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            song.displayTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: Container(
                        height: 38,
                        width: 38,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: AppTheme.primary,
                          size: 24,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ============================================================
// PLAYER PAGE
// ============================================================
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final AudioPlayerService _svc = AudioPlayerService.instance;
  bool _downloaded = false;
  bool _downloading = false;
  String? _checkedUrl;

  @override
  void initState() {
    super.initState();
    downloadsChanged.addListener(_recheck);
  }

  @override
  void dispose() {
    downloadsChanged.removeListener(_recheck);
    super.dispose();
  }

  void _recheck() => _checkDownloaded(_checkedUrl);

  Future<void> _checkDownloaded(String? url) async {
    if (url == null) return;
    final v = await AudioCacheService.isDownloaded(url);
    if (mounted && url == _checkedUrl) setState(() => _downloaded = v);
  }

  Future<void> _toggleDownload(Song song) async {
    if (_downloaded) {
      await AudioCacheService.deleteLocal(song.fileUrl);
      if (mounted) {
        showSnack(context, "Removed from downloads", Colors.grey.shade700);
      }
      return;
    }
    setState(() => _downloading = true);
    try {
      await AudioCacheService.downloadSong(song.fileUrl);
      if (mounted) {
        showSnack(
          context,
          "'${song.displayTitle}' saved offline",
          AppTheme.primary,
        );
      }
    } catch (_) {
      if (mounted) {
        showSnack(context, "Download failed – check connection", Colors.red);
      }
    }
    if (mounted) setState(() => _downloading = false);
  }

  void _showOptions(Song song) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: StreamBuilder<double>(
          stream: _svc.player.speedStream,
          builder: (_, snap) {
            final speed = snap.data ?? 1.0;
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Playback speed",
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: [0.75, 1.0, 1.25, 1.5, 2.0].map((s) {
                      return ChoiceChip(
                        label: Text("${s}x"),
                        selected: speed == s,
                        selectedColor: AppTheme.primary.withValues(alpha: 0.2),
                        onSelected: (_) => _svc.player.setSpeed(s),
                      );
                    }).toList(),
                  ),
                  const Divider(height: 28),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      _downloaded
                          ? Icons.delete_outline
                          : Icons.download_outlined,
                      color: AppTheme.primary,
                    ),
                    title: Text(
                      _downloaded
                          ? "Remove from downloads"
                          : "Save for offline listening",
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _toggleDownload(song);
                    },
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return "$m:$s";
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final pad = MediaQuery.of(context).padding;
    // Fits small phones (iPhone SE) without clipping the controls.
    final art = math.min(
      size.width * 0.86,
      (size.height - pad.vertical) * 0.42,
    );
    return ValueListenableBuilder<Song?>(
      valueListenable: _svc.currentSong,
      builder: (_, song, _) {
        if (song == null) {
          return const Scaffold(
            backgroundColor: Color(0xFFF0F9F0),
            body: Center(
              child: CircularProgressIndicator(color: AppTheme.primary),
            ),
          );
        }
        if (_checkedUrl != song.fileUrl) {
          _checkedUrl = song.fileUrl;
          _checkDownloaded(song.fileUrl);
        }
        final idx = _svc.queue.indexOf(song);
        final img = _farmImages[(idx >= 0 ? idx : 0) % _farmImages.length];
        final title = song.displayTitle;

        return Scaffold(
          backgroundColor: const Color(0xFFF0F9F0),
          body: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0xFFBBDEBB),
                  Color(0xFFE8F5E9),
                  Color(0xFFF0F9F0),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.0, 0.5, 1.0],
              ),
            ),
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Top bar ──
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: "Close",
                          icon: const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: AppTheme.primaryDark,
                            size: 30,
                          ),
                          onPressed: () => Navigator.pop(context),
                        ),
                        const Expanded(
                          child: Text(
                            "NOW PLAYING",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppTheme.primary,
                              fontSize: 11,
                              letterSpacing: 1.8,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: "Options",
                          icon: const Icon(
                            Icons.more_horiz_rounded,
                            color: AppTheme.primaryDark,
                            size: 26,
                          ),
                          onPressed: () => _showOptions(song),
                        ),
                      ],
                    ),
                  ),

                  const Spacer(),

                  // ── Album Art ──
                  Center(
                    child: Container(
                      width: art,
                      height: art,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.primaryDark.withValues(alpha: 0.45),
                            blurRadius: 40,
                            spreadRadius: 4,
                            offset: const Offset(0, 18),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.asset(img, fit: BoxFit.cover),
                      ),
                    ),
                  ),

                  const Spacer(flex: 2),

                  // ── Song Info + Download ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppTheme.primaryDark,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                  height: 1.25,
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                "ANGRAU Farm Advisory",
                                style: TextStyle(
                                  color: AppTheme.primary,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        _downloading
                            ? const SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: AppTheme.primary,
                                ),
                              )
                            : IconButton(
                                tooltip: _downloaded
                                    ? "Remove download"
                                    : "Save for offline listening",
                                icon: Icon(
                                  _downloaded
                                      ? Icons.download_done_rounded
                                      : Icons.download_outlined,
                                  color: AppTheme.primary,
                                  size: 28,
                                ),
                                onPressed: () => _toggleDownload(song),
                              ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // ── Seek Bar ──
                  StreamBuilder<Duration>(
                    stream: _svc.player.positionStream,
                    builder: (_, snap) {
                      final pos = snap.data ?? Duration.zero;
                      final total = _svc.player.duration ?? Duration.zero;
                      final maxVal = total.inMilliseconds.toDouble().clamp(
                        1.0,
                        double.infinity,
                      );
                      final val = pos.inMilliseconds.toDouble().clamp(
                        0.0,
                        maxVal,
                      );
                      return Column(
                        children: [
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3.5,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 16,
                              ),
                              activeTrackColor: AppTheme.primaryDark,
                              inactiveTrackColor: const Color(0xFF81C784),
                              thumbColor: AppTheme.primaryDark,
                              overlayColor: const Color(0x2A2E7D32),
                            ),
                            child: Slider(
                              min: 0,
                              max: maxVal,
                              value: val,
                              onChanged: (v) => _svc.player.seek(
                                Duration(milliseconds: v.toInt()),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 26),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _fmt(pos),
                                  style: const TextStyle(
                                    color: AppTheme.primary,
                                    fontSize: 11,
                                  ),
                                ),
                                Text(
                                  "${(idx >= 0 ? idx : 0) + 1} / ${_svc.queue.length}",
                                  style: const TextStyle(
                                    color: AppTheme.primary,
                                    fontSize: 11,
                                  ),
                                ),
                                Text(
                                  _fmt(total),
                                  style: const TextStyle(
                                    color: AppTheme.primary,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),

                  const SizedBox(height: 10),

                  // ── Main Controls: Shuffle | Prev | Play | Next | Repeat ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        // Shuffle
                        StreamBuilder<bool>(
                          stream: _svc.player.shuffleModeEnabledStream,
                          builder: (_, s) {
                            final on = s.data ?? false;
                            return IconButton(
                              tooltip: on ? "Shuffle on" : "Shuffle off",
                              iconSize: 24,
                              icon: Icon(
                                on
                                    ? Icons.shuffle_on_rounded
                                    : Icons.shuffle_rounded,
                                color: on
                                    ? AppTheme.primaryDark
                                    : AppTheme.primary.withValues(alpha: 0.6),
                              ),
                              onPressed: _svc.toggleShuffle,
                            );
                          },
                        ),
                        // Previous
                        IconButton(
                          tooltip: "Previous",
                          iconSize: 36,
                          icon: const Icon(
                            Icons.skip_previous_rounded,
                            color: AppTheme.primaryDark,
                          ),
                          onPressed: _svc.previous,
                        ),
                        // Play / Pause
                        StreamBuilder<PlayerState>(
                          stream: _svc.player.playerStateStream,
                          builder: (_, s) {
                            final state = s.data;
                            final playing = state?.playing ?? false;
                            final loading =
                                state?.processingState ==
                                    ProcessingState.loading ||
                                state?.processingState ==
                                    ProcessingState.buffering;
                            return Semantics(
                              button: true,
                              label: playing ? "Pause" : "Play",
                              child: GestureDetector(
                                onTap: () => playing
                                    ? _svc.player.pause()
                                    : _svc.player.play(),
                                child: Container(
                                  height: 68,
                                  width: 68,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: AppTheme.primaryDark,
                                    boxShadow: [
                                      BoxShadow(
                                        color: AppTheme.primaryDark.withValues(
                                          alpha: 0.35,
                                        ),
                                        blurRadius: 20,
                                        spreadRadius: 2,
                                      ),
                                    ],
                                  ),
                                  child: loading && playing
                                      ? const Padding(
                                          padding: EdgeInsets.all(22),
                                          child: CircularProgressIndicator(
                                            color: Colors.white,
                                            strokeWidth: 2.5,
                                          ),
                                        )
                                      : Icon(
                                          playing
                                              ? Icons.pause_rounded
                                              : Icons.play_arrow_rounded,
                                          color: Colors.white,
                                          size: 40,
                                        ),
                                ),
                              ),
                            );
                          },
                        ),
                        // Next
                        IconButton(
                          tooltip: "Next",
                          iconSize: 36,
                          icon: const Icon(
                            Icons.skip_next_rounded,
                            color: AppTheme.primaryDark,
                          ),
                          onPressed: _svc.next,
                        ),
                        // Repeat: off -> all -> one
                        StreamBuilder<LoopMode>(
                          stream: _svc.player.loopModeStream,
                          builder: (_, s) {
                            final mode = s.data ?? LoopMode.off;
                            return IconButton(
                              tooltip: mode == LoopMode.one
                                  ? "Repeat this broadcast"
                                  : mode == LoopMode.all
                                  ? "Repeat all"
                                  : "Repeat off",
                              iconSize: 24,
                              icon: Icon(
                                mode == LoopMode.one
                                    ? Icons.repeat_one_on_rounded
                                    : mode == LoopMode.all
                                    ? Icons.repeat_on_rounded
                                    : Icons.repeat_rounded,
                                color: mode == LoopMode.off
                                    ? AppTheme.primary.withValues(alpha: 0.6)
                                    : AppTheme.primaryDark,
                              ),
                              onPressed: _svc.cycleRepeat,
                            );
                          },
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 6),

                  // ── Seek -10 / +10 ──
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: "Back 10 seconds",
                        color: AppTheme.primary,
                        onPressed: () =>
                            _svc.seekBy(const Duration(seconds: -10)),
                        icon: const Icon(Icons.replay_10_rounded, size: 26),
                      ),
                      const SizedBox(width: 40),
                      IconButton(
                        tooltip: "Forward 10 seconds",
                        color: AppTheme.primary,
                        onPressed: () =>
                            _svc.seekBy(const Duration(seconds: 10)),
                        icon: const Icon(Icons.forward_10_rounded, size: 26),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ============================================================
// DOWNLOADS PAGE
// ============================================================
class DownloadsPage extends StatefulWidget {
  final List<Song> songs;
  final Function(Song) onPlay;
  const DownloadsPage({super.key, required this.songs, required this.onPlay});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  List<Song> _local = [];
  double _sizeMB = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    downloadsChanged.addListener(_load);
  }

  @override
  void didUpdateWidget(DownloadsPage old) {
    super.didUpdateWidget(old);
    if (old.songs != widget.songs) _load();
  }

  @override
  void dispose() {
    downloadsChanged.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    if (_local.isEmpty && mounted) setState(() => _loading = true);
    final result = <Song>[];
    for (final s in widget.songs) {
      if (await AudioCacheService.isDownloaded(s.fileUrl)) result.add(s);
    }
    final sz = await AudioCacheService.totalSizeMB();
    if (mounted) {
      setState(() {
        _local = result;
        _sizeMB = sz;
        _loading = false;
      });
    }
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("Clear All Downloads"),
        content: const Text("Remove all offline audio files from this device?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Clear"),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final s in List.of(_local)) {
      await AudioCacheService.deleteLocal(s.fileUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.cream,
      appBar: AppBar(
        title: const Text(
          "Downloads",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        elevation: 0,
        automaticallyImplyLeading: false,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [AppTheme.primaryDark, AppTheme.primary],
            ),
          ),
        ),
        actions: [
          if (_local.isNotEmpty)
            IconButton(
              icon: const Icon(
                Icons.delete_sweep_outlined,
                color: Colors.white,
              ),
              onPressed: _clearAll,
              tooltip: "Clear all",
            ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: _load,
            tooltip: "Refresh",
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primary),
            )
          : _local.isEmpty
          ? _empty()
          : Column(
              children: [
                _statsBar(),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(14),
                    itemCount: _local.length,
                    itemBuilder: (_, i) => _LocalCard(
                      song: _local[i],
                      onPlay: widget.onPlay,
                      onRemove: () =>
                          AudioCacheService.deleteLocal(_local[i].fileUrl),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _statsBar() => Container(
    margin: const EdgeInsets.all(14),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(14),
      gradient: const LinearGradient(
        colors: [Color(0xFF33691E), Color(0xFF558B2F)],
      ),
    ),
    child: Row(
      children: [
        const Icon(Icons.download_done_rounded, color: Colors.white, size: 30),
        const SizedBox(width: 14),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "${_local.length} broadcast${_local.length == 1 ? '' : 's'} saved offline",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              "${_sizeMB.toStringAsFixed(1)} MB used",
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _empty() => const Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.download_outlined, size: 72, color: Colors.grey),
        SizedBox(height: 16),
        Text(
          "No downloads yet",
          style: TextStyle(fontSize: 16, color: Colors.grey),
        ),
        SizedBox(height: 8),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            "Tap the download button next to any broadcast to listen without internet",
            style: TextStyle(fontSize: 13, color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    ),
  );
}

class _LocalCard extends StatelessWidget {
  final Song song;
  final Function(Song) onPlay;
  final VoidCallback onRemove;
  const _LocalCard({
    required this.song,
    required this.onPlay,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ListTile(
        onTap: () => onPlay(song),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: Container(
          height: 46,
          width: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: const LinearGradient(
              colors: [AppTheme.primary, AppTheme.primaryLight],
            ),
          ),
          child: const Icon(
            Icons.music_note_rounded,
            color: Colors.white,
            size: 22,
          ),
        ),
        title: Text(
          song.displayTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
        subtitle: const Row(
          children: [
            Icon(Icons.offline_bolt_rounded, size: 12, color: AppTheme.primary),
            SizedBox(width: 4),
            Text(
              "Available offline",
              style: TextStyle(fontSize: 12, color: AppTheme.primary),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: "Play",
              icon: const Icon(
                Icons.play_arrow_rounded,
                color: AppTheme.primary,
                size: 26,
              ),
              onPressed: () => onPlay(song),
            ),
            IconButton(
              tooltip: "Remove download",
              icon: const Icon(
                Icons.delete_outline,
                color: Colors.red,
                size: 20,
              ),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// SETTINGS PAGE
// ============================================================
class SettingsPage extends StatefulWidget {
  final VoidCallback onUpdate;
  final List<Song> songs;
  final void Function(List<Song>) onSongsUpdated;
  final Future<void> Function() onRefresh;
  const SettingsPage({
    super.key,
    required this.onUpdate,
    required this.songs,
    required this.onSongsUpdated,
    required this.onRefresh,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _loggedIn = false;
  String? _adminName;

  @override
  void initState() {
    super.initState();
    _readLogin();
  }

  Future<void> _readLogin() async {
    final v = await AuthPrefs.isLoggedIn();
    final n = await AuthPrefs.name();
    if (mounted) {
      setState(() {
        _loggedIn = v;
        _adminName = n;
      });
    }
  }

  Future<void> _openAdmin() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AdminPanel(
          songs: widget.songs,
          onSongsUpdated: widget.onSongsUpdated,
        ),
      ),
    );
    await _readLogin(); // the panel signs out if the session expired
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.cream,
      appBar: AppBar(
        title: const Text(
          "Settings & About",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        elevation: 0,
        automaticallyImplyLeading: false,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [AppTheme.primaryDark, AppTheme.primary],
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _aboutCard(),
          const SizedBox(height: 16),

          _section("STORAGE"),
          _tile(
            Icons.cached_rounded,
            "Refresh Broadcast List",
            "Clear the saved list and load it again from the server",
            Colors.orange,
            () async {
              await SongCacheService.clear();
              await widget.onRefresh();
              if (context.mounted) {
                showSnack(
                  context,
                  "Broadcast list refreshed",
                  AppTheme.primary,
                );
              }
            },
          ),

          _section("HELP & INFORMATION"),
          _tile(
            Icons.help_outline_rounded,
            "How to Use",
            "Listening, downloads and playback",
            AppTheme.primary,
            () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HelpPage()),
              );
            },
          ),
          _tile(
            Icons.call_rounded,
            "ANGRAU Helpline",
            "Toll-free ${AppLinks.helplineLabel}",
            Colors.teal,
            () => callHelpline(context),
          ),
          _tile(
            Icons.language_rounded,
            "University Website",
            "angrau.ac.in",
            Colors.blue,
            () => openWebPage(context, AppLinks.website),
          ),
          _tile(
            Icons.privacy_tip_outlined,
            "Privacy Policy",
            "What the app does with information",
            Colors.indigo,
            () => openWebPage(context, AppLinks.privacy),
          ),
          _tile(
            Icons.support_agent_rounded,
            "Support",
            "Questions or problems with the app",
            Colors.deepPurple,
            () => openWebPage(context, AppLinks.support),
          ),

          _section("STAFF"),
          if (!_loggedIn)
            _tile(
              Icons.login_rounded,
              "Admin Login",
              "For ANGRAU staff who publish broadcasts",
              AppTheme.primary,
              () async {
                final ok = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(builder: (_) => const LoginPage()),
                );
                await _readLogin();
                if (ok == true) {
                  await widget.onRefresh();
                  if (mounted) await _openAdmin();
                }
              },
            ),
          if (_loggedIn) ...[
            _tile(
              Icons.admin_panel_settings_rounded,
              "Admin Panel",
              "Upload and manage audio content",
              AppTheme.primaryDark,
              _openAdmin,
            ),
            _tile(
              Icons.logout_rounded,
              "Logout",
              "Signed in as ${_adminName ?? 'admin'}",
              Colors.red,
              () async {
                await AuthPrefs.logout();
                setState(() => _loggedIn = false);
                await widget.onRefresh();
                widget.onUpdate();
                if (context.mounted) {
                  showSnack(
                    context,
                    "Logged out successfully",
                    Colors.grey.shade700,
                  );
                }
              },
            ),
          ],

          _section("ABOUT"),
          _tile(
            Icons.info_outline_rounded,
            "App Version",
            "ANGRAU Farm Radio ${AppLinks.version}",
            Colors.blue,
            null,
          ),
          _tile(
            Icons.agriculture,
            "About ANGRAU",
            "Acharya N.G. Ranga Agricultural University, Guntur, A.P.",
            AppTheme.earth,
            null,
          ),

          const SizedBox(height: 24),
          _developerCard(),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _aboutCard() => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(18),
      gradient: const LinearGradient(
        colors: [AppTheme.primaryDark, Color(0xFF388E3C)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    child: Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.asset(
            "assets/images/angrauicon.png",
            height: 64,
            width: 64,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: 16),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "ANGRAU Farm Radio",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 4),
              Text(
                "Agricultural Advisory Platform",
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              SizedBox(height: 8),
              Text(
                "Version ${AppLinks.version}",
                style: TextStyle(color: Colors.white60, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _section(String t) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Text(
      t,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: AppTheme.textLight,
        letterSpacing: 1.2,
      ),
    ),
  );

  Widget _tile(
    IconData icon,
    String title,
    String sub,
    Color color,
    VoidCallback? onTap,
  ) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(14),
      color: Colors.white,
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.05),
          blurRadius: 6,
          offset: const Offset(0, 2),
        ),
      ],
    ),
    child: ListTile(
      leading: Container(
        height: 42,
        width: 42,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: color.withValues(alpha: 0.12),
        ),
        child: Icon(icon, color: color, size: 22),
      ),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
      subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
      trailing: onTap != null
          ? const Icon(Icons.chevron_right, color: Colors.grey)
          : null,
      onTap: onTap,
    ),
  );

  Widget _developerCard() => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
      color: Colors.white,
    ),
    child: const Column(
      children: [
        Icon(Icons.person_rounded, color: AppTheme.primary, size: 36),
        SizedBox(height: 10),
        Text(
          "DR. P.B. PRADEEP KUMAR",
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
        SizedBox(height: 4),
        Text(
          "Senior Scientist & Coordinator\nDAATTC-PADERU, Alluri Sitaramaraju District\nAcharya N.G. Ranga Agricultural University\nGuntur, Andhra Pradesh",
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: AppTheme.textMid, height: 1.6),
        ),
      ],
    ),
  );
}

// ============================================================
// HELP PAGE
// ============================================================
class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  static const _items = [
    (
      Icons.play_circle_outline_rounded,
      "Listen to a broadcast",
      "Tap any broadcast on the Home screen. The player opens and the broadcast starts. When it ends, the next one plays.",
    ),
    (
      Icons.download_outlined,
      "Listen without internet",
      "Tap the download button next to a broadcast. Saved broadcasts are listed in the Downloads tab and play without internet.",
    ),
    (
      Icons.lock_outline_rounded,
      "Listen with the screen off",
      "Playback continues when you lock your phone or switch to another app. Use the lock screen or Control Center to pause or skip.",
    ),
    (
      Icons.repeat_rounded,
      "Shuffle, repeat and speed",
      "In the player, tap shuffle or repeat. Tap ••• to change the playback speed.",
    ),
    (
      Icons.refresh_rounded,
      "Get new broadcasts",
      "Pull down on the Home screen to load the latest broadcasts from the university.",
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.cream,
      appBar: AppBar(
        title: const Text(
          "Help",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        elevation: 0,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [AppTheme.primaryDark, AppTheme.primary],
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final (icon, title, body) in _items)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: Colors.white,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, color: AppTheme.primary, size: 26),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          body,
                          style: const TextStyle(
                            fontSize: 13.5,
                            color: AppTheme.textMid,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 10),
          const Text(
            "Still need help?",
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              ElevatedButton.icon(
                onPressed: () => callHelpline(context),
                icon: const Icon(Icons.call_rounded, size: 18),
                label: const Text("Helpline ${AppLinks.helplineLabel}"),
              ),
              OutlinedButton.icon(
                onPressed: () => openWebPage(context, AppLinks.support),
                icon: const Icon(Icons.support_agent_rounded, size: 18),
                label: const Text("Support page"),
              ),
            ],
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}

// ============================================================
// ADMIN PANEL (with drag-drop reorder)
// ============================================================
class AdminPanel extends StatefulWidget {
  final List<Song> songs;
  final void Function(List<Song>) onSongsUpdated;
  const AdminPanel({
    super.key,
    required this.songs,
    required this.onSongsUpdated,
  });

  @override
  State<AdminPanel> createState() => _AdminPanelState();
}

class _AdminPanelState extends State<AdminPanel> {
  static const _audioExtensions = [
    'mp3',
    'm4a',
    'aac',
    'wav',
    'mp4',
    'ogg',
    'opus',
    'amr',
    'mpeg',
    'flac',
  ];

  late List<Song> _songs;
  bool _savingOrder = false;

  @override
  void initState() {
    super.initState();
    _songs = List.from(widget.songs);
  }

  @override
  void didUpdateWidget(AdminPanel old) {
    super.didUpdateWidget(old);
    if (old.songs != widget.songs) {
      _songs = List.from(widget.songs);
    }
  }

  /// Shows the error; if the login expired, signs out and leaves the panel.
  Future<void> _handleError(String action, Object e) async {
    if (e is ApiException && e.sessionExpired) {
      await AuthPrefs.logout();
      if (!mounted) return;
      _snack("Your login has expired. Please log in again.", Colors.red);
      Navigator.pop(context);
      return;
    }
    _snack("$action failed: ${errorText(e)}", Colors.red);
  }

  Future<void> _reloadFromServer() async {
    final updated = await ApiService.fetchSongs();
    await SongCacheService.save(updated);
    allSongs = updated;
    if (!mounted) return;
    setState(() => _songs = List.from(updated));
    widget.onSongsUpdated(updated);
  }

  Future<void> _upload() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: _audioExtensions,
      );
    } catch (e) {
      _snack("Could not open files: $e", Colors.red);
      return;
    }
    final path = result?.files.single.path;
    if (path == null) return;

    _showLoading("Uploading audio...");
    try {
      await ApiService.uploadSong(path);
      await _reloadFromServer();
      if (!mounted) return;
      Navigator.pop(context); // close loading
      await _showSuccess("Audio uploaded successfully!");
    } catch (e) {
      if (mounted) Navigator.pop(context);
      await _handleError("Upload", e);
    }
  }

  Future<void> _delete(Song song) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("Delete Audio"),
        content: Text(
          "Delete \"${song.displayTitle}\"?\n\nThis removes it from the app.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await ApiService.deleteSong(song.id);
      await _reloadFromServer();
      _snack("Deleted", Colors.grey.shade700);
    } catch (e) {
      await _handleError("Delete", e);
    }
  }

  Future<void> _saveOrder() async {
    setState(() => _savingOrder = true);
    try {
      await ApiService.reorderSongs(_songs);
      await SongCacheService.save(_songs);
      allSongs = _songs;
      widget.onSongsUpdated(List.of(_songs));
      _snack("Order saved!", AppTheme.primary);
    } catch (e) {
      await _handleError("Saving the order", e);
    }
    if (mounted) setState(() => _savingOrder = false);
  }

  void _showLoading(String msg) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppTheme.primary),
            const SizedBox(height: 16),
            Text(msg, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Future<void> _showSuccess(String msg) async {
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Icon(
          Icons.check_circle_rounded,
          color: AppTheme.primary,
          size: 52,
        ),
        content: Text(msg, textAlign: TextAlign.center),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("OK"),
          ),
        ],
      ),
    );
  }

  void _snack(String msg, Color bg) {
    if (!mounted) return;
    showSnack(context, msg, bg);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.cream,
      appBar: AppBar(
        title: const Text(
          "Admin Panel",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        elevation: 0,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [AppTheme.earth, Color(0xFFA1887F)],
            ),
          ),
        ),
        actions: [
          if (_songs.isNotEmpty)
            _savingOrder
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    ),
                  )
                : TextButton.icon(
                    icon: const Icon(
                      Icons.save_rounded,
                      color: Colors.white,
                      size: 18,
                    ),
                    label: const Text(
                      "Save Order",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onPressed: _saveOrder,
                  ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _upload,
        icon: const Icon(Icons.upload_rounded),
        label: const Text(
          "Upload Audio",
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        backgroundColor: AppTheme.earth,
        foregroundColor: Colors.white,
      ),
      body: _songs.isEmpty
          ? _empty()
          : Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  color: Colors.white,
                  child: Row(
                    children: [
                      const Icon(
                        Icons.drag_indicator_rounded,
                        color: Colors.grey,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          "${_songs.length} audios – drag to reorder, tap Save Order",
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 100),
                    itemCount: _songs.length,
                    onReorderItem: (oldIdx, newIdx) {
                      setState(() {
                        final item = _songs.removeAt(oldIdx);
                        _songs.insert(newIdx, item);
                      });
                    },
                    itemBuilder: (_, i) {
                      final s = _songs[i];
                      return _AdminCard(
                        key: ValueKey(s.id),
                        song: s,
                        index: i,
                        onDelete: () => _delete(s),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }

  Widget _empty() => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.audio_file_outlined, size: 72, color: Colors.grey),
        const SizedBox(height: 16),
        const Text(
          "No audio uploaded yet",
          style: TextStyle(fontSize: 16, color: Colors.grey),
        ),
        const SizedBox(height: 24),
        ElevatedButton.icon(
          onPressed: _upload,
          icon: const Icon(Icons.upload_rounded),
          label: const Text("Upload First Audio"),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.earth,
            foregroundColor: Colors.white,
          ),
        ),
      ],
    ),
  );
}

class _AdminCard extends StatelessWidget {
  final Song song;
  final int index;
  final VoidCallback onDelete;
  const _AdminCard({
    super.key,
    required this.song,
    required this.index,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 24,
              child: Text(
                "${index + 1}",
                style: const TextStyle(
                  color: Colors.grey,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              height: 44,
              width: 44,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Color(0xFF558B2F), Color(0xFF8BC34A)],
                ),
              ),
              child: const Icon(
                Icons.music_note_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
          ],
        ),
        title: Text(
          song.displayTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
        subtitle: const Text(
          "Audio Advisory",
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: "Delete",
              icon: const Icon(
                Icons.delete_outline,
                color: Colors.red,
                size: 22,
              ),
              onPressed: onDelete,
            ),
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.drag_handle_rounded, color: Colors.grey),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// LOGIN PAGE
// ============================================================
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _obscure = true;
  String? _error;
  bool _loading = false;

  Future<void> _login() async {
    final user = _userCtrl.text.trim();
    if (user.isEmpty || _passCtrl.text.isEmpty) {
      setState(() => _error = "Enter your username and password.");
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ApiService.login(user, _passCtrl.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = errorText(e);
          _loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.cream,
      body: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Column(
          children: [
            // Header gradient
            Container(
              width: double.infinity,
              padding: EdgeInsets.fromLTRB(
                12,
                MediaQuery.of(context).padding.top + 4,
                24,
                40,
              ),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppTheme.primaryDark,
                    AppTheme.primary,
                    Color(0xFF66BB6A),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(40),
                  bottomRight: Radius.circular(40),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconButton(
                    tooltip: "Back",
                    icon: Icon(Icons.adaptive.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.pop(context, false),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 12, top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipOval(
                          child: Image.asset(
                            "assets/images/angrauicon.png",
                            height: 58,
                            width: 58,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          "Admin Login",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          "For ANGRAU staff who publish broadcasts.\nListening needs no login.",
                          style: TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.all(24),
              child: AutofillGroup(
                child: Column(
                  children: [
                    const SizedBox(height: 20),

                    if (_error != null) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          color: Colors.red.shade50,
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.error_outline,
                              color: Colors.red,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error!,
                                style: const TextStyle(
                                  color: Colors.red,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // Username field
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.07),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: TextField(
                        controller: _userCtrl,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.username],
                        decoration: const InputDecoration(
                          hintText: "Username",
                          prefixIcon: Icon(
                            Icons.person_rounded,
                            color: AppTheme.primary,
                          ),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 16),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Password field
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.07),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: TextField(
                        controller: _passCtrl,
                        obscureText: _obscure,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.password],
                        onSubmitted: (_) => _login(),
                        decoration: InputDecoration(
                          hintText: "Password",
                          prefixIcon: const Icon(
                            Icons.lock_rounded,
                            color: AppTheme.primary,
                          ),
                          suffixIcon: IconButton(
                            tooltip: _obscure
                                ? "Show password"
                                : "Hide password",
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              color: Colors.grey,
                            ),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 16,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),

                    // Login button
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: _loading ? null : _login,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primary,
                          foregroundColor: Colors.white,
                          elevation: 4,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: _loading
                            ? const SizedBox(
                                height: 22,
                                width: 22,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text(
                                "Login",
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
