import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

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
        colorScheme: const ColorScheme.light(
          primary: primary,
          secondary: amber,
        ),
        fontFamily: 'Roboto',
        appBarTheme: const AppBarTheme(backgroundColor: primary),
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

// ============================================================
// AUDIO PLAYER SERVICE (singleton)
// ============================================================
class AudioPlayerService {
  static final AudioPlayerService _inst = AudioPlayerService._();
  static AudioPlayerService get instance => _inst;
  AudioPlayerService._();

  final AudioPlayer player = AudioPlayer();
  final ValueNotifier<Song?> currentSong = ValueNotifier(null);
  List<Song> queue = [];
  int _idx = 0;

  int get currentIndex => _idx;

  Future<void> playFromQueue(List<Song> songs, int index) async {
    queue = songs;
    _idx = index;
    await _playCurrent();
  }

  Future<void> _playCurrent() async {
    if (queue.isEmpty) return;
    final song = queue[_idx];
    currentSong.value = song;
    try {
      await player.stop();
      if (song.fileUrl.startsWith('/')) {
        await player.setFilePath(song.fileUrl);
      } else {
        final local = await AudioCacheService.getLocalPath(song.fileUrl);
        if (File(local).existsSync()) {
          await player.setFilePath(local);
        } else {
          await player.setUrl(song.fileUrl);
        }
      }
      await player.play();
    } catch (e) {
      debugPrint('Audio error: $e');
    }
  }

  Future<void> next() async {
    if (_idx < queue.length - 1) {
      _idx++;
      await _playCurrent();
    }
  }

  Future<void> previous() async {
    if (_idx > 0) {
      _idx--;
      await _playCurrent();
    }
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
class ApiService {
  static const String baseUrl = "https://api.chandus7.in/api/farmradio";

  static Future<List<Song>> fetchSongs() async {
    final res = await http
        .get(Uri.parse("$baseUrl/songs/"))
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) throw Exception("Server error ${res.statusCode}");
    final List data = jsonDecode(res.body);
    return data.map((e) => Song.fromJson(e)).toList();
  }

  static Future<void> deleteSong(int id) async {
    await http.delete(Uri.parse("$baseUrl/songs/$id/"));
  }

  static Future<void> uploadSong(String path) async {
    final req = http.MultipartRequest("POST", Uri.parse("$baseUrl/songs/upload/"));
    req.files.add(await http.MultipartFile.fromPath("file", path));
    final res = await req.send();
    if (res.statusCode != 201) throw Exception("Upload failed ${res.statusCode}");
  }

  static Future<void> reorderSongs(List<Song> songs) async {
    final body = jsonEncode(
      songs.asMap().entries.map((e) => {'id': e.value.id, 'order': e.key}).toList(),
    );
    await http.patch(
      Uri.parse("$baseUrl/songs/reorder/"),
      headers: {"Content-Type": "application/json"},
      body: body,
    );
  }
}

// ============================================================
// SONG CACHE SERVICE
// ============================================================
class SongCacheService {
  static const String _key = 'cached_songs_v2';

  static Future<void> save(List<Song> songs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(songs.map((s) => s.toJson()).toList()));
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
    final d = await getApplicationDocumentsDirectory();
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
    final res = await http.get(Uri.parse(fileUrl));
    await file.writeAsBytes(res.bodyBytes);
    return path;
  }

  static Future<void> deleteLocal(String fileUrl) async {
    final path = await getLocalPath(fileUrl);
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  }

  static Future<double> totalSizeMB() async {
    final d = await _dir();
    double total = 0;
    for (final f in d.listSync().whereType<File>()) {
      total += f.lengthSync();
    }
    return total / (1024 * 1024);
  }

  static Future<List<Song>> localOnlySongs() async {
    final d = await _dir();
    final files = d.listSync().whereType<File>().toList();
    return files.asMap().entries.map((e) {
      final name = e.value.path.split('/').last;
      return Song(
        id: e.key,
        title: name.replaceAll(RegExp(r'\.[^.]+$'), ''),
        fileUrl: e.value.path,
      );
    }).toList();
  }
}

// ============================================================
// AUTH PREFS
// ============================================================
class AuthPrefs {
  static const String _key = 'is_admin_logged_in';

  static Future<void> setLoggedIn(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_key, v);
  }

  static Future<bool> isLoggedIn() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_key) ?? false;
  }

  static Future<void> logout() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_key, false);
  }
}

// ============================================================
// MAIN
// ============================================================
void main() => runApp(const FarmRadioApp());

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
    const totalMs = 5000;
    const tickMs = 50;
    int elapsed = 0;
    _timer = Timer.periodic(const Duration(milliseconds: tickMs), (t) {
      elapsed += tickMs;
      if (!mounted) { t.cancel(); return; }
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

    _setStatus("Loading saved songs...");
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
    const min = Duration(seconds: 5);
    if (elapsed < min) await Future.delayed(min - elapsed);

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
// MAIN SHELL (4-tab navigation)
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
  }

  void _updateSongs(List<Song> updated) {
    setState(() {
      _songs = updated;
      allSongs = updated;
    });
  }

  void _openPlayer(Song song) {
    final index = _songs.indexOf(song);
    if (index == -1) return;
    AudioPlayerService.instance.playFromQueue(_songs, index);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerPage(songs: _songs, initialIndex: index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        final now = DateTime.now();
        if (_lastBack == null ||
            now.difference(_lastBack!) > const Duration(seconds: 2)) {
          _lastBack = now;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Press back again to exit"),
              behavior: SnackBarBehavior.floating,
              duration: Duration(seconds: 2),
            ),
          );
          return false;
        }
        return true;
      },
      child: Scaffold(
        body: IndexedStack(
          index: _tab,
          children: [
            HomePage(songs: _songs, onPlay: _openPlayer),
            DownloadsPage(songs: _songs, onPlay: _openPlayer),
            SettingsPage(
              onUpdate: () => setState(() {}),
              songs: _songs,
              onSongsUpdated: _updateSongs,
            ),
          ],
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _MiniPlayer(onTap: () {
              final svc = AudioPlayerService.instance;
              if (svc.currentSong.value != null) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PlayerPage(
                      songs: _songs,
                      initialIndex: svc.currentIndex,
                    ),
                  ),
                );
              }
            }),
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
      builder: (_, song, __) {
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
                  color: AppTheme.primary.withOpacity(0.35),
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
                    color: Colors.white.withOpacity(0.15),
                  ),
                  child: const Icon(Icons.music_note_rounded,
                      color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title.replaceAll(RegExp(r'\.[^.]+$'), ''),
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
                          icon: const Icon(Icons.skip_next_rounded,
                              color: Colors.white, size: 24),
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
  const HomePage({super.key, required this.songs, required this.onPlay});

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
                borderRadius: BorderRadius.circular(12)),
            onSelected: (value) {
              if (value == 'about') {
                showAboutDialog(
                  context: context,
                  applicationName: 'ANGRAU Farm Radio',
                  applicationVersion: 'v2.0',
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
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'about',
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded,
                        color: AppTheme.primary, size: 20),
                    SizedBox(width: 10),
                    Text("About App"),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'help',
                child: Row(
                  children: [
                    Icon(Icons.help_outline_rounded,
                        color: AppTheme.primary, size: 20),
                    SizedBox(width: 10),
                    Text("Help"),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: songs.isEmpty
          ? _emptyState()
          : ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                const SizedBox(height: 14),
                _header("Featured"),
                const SizedBox(height: 8),
                _AutoCarousel(songs: songs, onSelect: onPlay),
                const SizedBox(height: 20),
                _header("All Broadcasts (${songs.length})"),
                const SizedBox(height: 8),
                ...songs.map((s) => _SongCard(song: s, onPlay: onPlay)),
                const SizedBox(height: 12),
              ],
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

  Widget _emptyState() => const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.radio, size: 72, color: Colors.grey),
            SizedBox(height: 16),
            Text("No broadcasts available",
                style: TextStyle(fontSize: 16, color: Colors.grey)),
            SizedBox(height: 8),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                "Check your internet connection or ask the admin to upload content",
                style: TextStyle(fontSize: 13, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      );
}

// ============================================================
// SONG CARD (with per-song download button)
// ============================================================
class _SongCard extends StatefulWidget {
  final Song song;
  final Function(Song) onPlay;
  const _SongCard({required this.song, required this.onPlay});

  @override
  State<_SongCard> createState() => _SongCardState();
}

class _SongCardState extends State<_SongCard> {
  bool _downloaded = false;
  bool _downloading = false;

  String get _title => widget.song.title.replaceAll(RegExp(r'\.[^.]+$'), '');

  @override
  void initState() {
    super.initState();
    _checkDownloaded();
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
        if (mounted) setState(() {
          _downloaded = true;
          _downloading = false;
        });
        _snack("'$_title' saved offline", AppTheme.primary);
      } catch (_) {
        if (mounted) setState(() => _downloading = false);
        _snack("Download failed – check connection", Colors.red);
      }
    }
  }

  void _snack(String msg, Color bg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: bg,
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Song?>(
      valueListenable: AudioPlayerService.instance.currentSong,
      builder: (_, current, __) {
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
                color: Colors.black.withOpacity(0.06),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
                        icon: Icon(
                          _downloaded
                              ? Icons.download_done_rounded
                              : Icons.download_outlined,
                          color:
                              _downloaded ? AppTheme.primary : Colors.grey,
                          size: 22,
                        ),
                        onPressed: _toggleDownload,
                        splashRadius: 20,
                      ),
                IconButton(
                  icon: Container(
                    height: 34,
                    width: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: active
                          ? AppTheme.primary
                          : AppTheme.primary.withOpacity(0.1),
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

class _AutoCarouselState extends State<_AutoCarousel> {
  late final PageController _ctrl;
  int _idx = 0;
  Timer? _timer;

  final List<String> _imgs = [
    "assets/images/farm1.PNG",
    "assets/images/farm2.PNG",
    "assets/images/farm3.png",
    "assets/images/farm4.PNG",
  ];

  @override
  void initState() {
    super.initState();
    _ctrl = PageController(viewportFraction: 0.82);
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_ctrl.hasClients || widget.songs.isEmpty) return;
      _idx = (_idx + 1) % widget.songs.length;
      _ctrl.animateToPage(_idx,
          duration: const Duration(milliseconds: 600), curve: Curves.easeInOut);
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
          final img = _imgs[i % _imgs.length];
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
                            Colors.black.withOpacity(0.72),
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
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: AppTheme.primary.withOpacity(0.85),
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
                            song.title.replaceAll(RegExp(r'\.[^.]+$'), ''),
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
                        child: const Icon(Icons.play_arrow_rounded,
                            color: AppTheme.primary, size: 24),
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
  final List<Song> songs;
  final int initialIndex;

  const PlayerPage({
    super.key,
    required this.songs,
    required this.initialIndex,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final AudioPlayerService _svc = AudioPlayerService.instance;
  bool _shuffle = false;
  bool _repeat = false;
  bool _liked = false;

  final List<String> _imgs = [
    "assets/images/farm1.PNG",
    "assets/images/farm2.PNG",
    "assets/images/farm3.png",
    "assets/images/farm4.PNG",
  ];

  @override
  void initState() {
    super.initState();
    if (_svc.queue != widget.songs ||
        _svc.currentIndex != widget.initialIndex) {
      _svc.playFromQueue(widget.songs, widget.initialIndex);
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return "$m:$s";
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    return ValueListenableBuilder<Song?>(
      valueListenable: _svc.currentSong,
      builder: (_, song, __) {
        if (song == null) {
          return const Scaffold(
              backgroundColor: Color(0xFFF0F9F0),
              body: Center(
                  child: CircularProgressIndicator(color: AppTheme.primary)));
        }
        final idx = widget.songs.indexOf(song);
        final img = _imgs[(idx >= 0 ? idx : 0) % _imgs.length];
        final title = song.title.replaceAll(RegExp(r'\.[^.]+$'), '');

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
                          icon: const Icon(Icons.more_horiz_rounded,
                              color: AppTheme.primaryDark, size: 26),
                          onPressed: () {},
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 14),

                  // ── Album Art ──
                  Center(
                    child: Container(
                      width: screenW * 0.82,
                      height: screenW * 0.82,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.primaryDark.withOpacity(0.45),
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

                  const SizedBox(height: 26),

                  // ── Song Info + Like ──
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
                                    color: AppTheme.primary, fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        GestureDetector(
                          onTap: () => setState(() => _liked = !_liked),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            child: Icon(
                              _liked
                                  ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                              key: ValueKey(_liked),
                              color: _liked
                                  ? Colors.red
                                  : AppTheme.primary,
                              size: 28,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  // ── Seek Bar ──
                  StreamBuilder<Duration>(
                    stream: _svc.player.positionStream,
                    builder: (_, snap) {
                      final pos = snap.data ?? Duration.zero;
                      final total = _svc.player.duration ?? Duration.zero;
                      final maxVal = total.inMilliseconds
                          .toDouble()
                          .clamp(1.0, double.infinity);
                      final val =
                          pos.inMilliseconds.toDouble().clamp(0.0, maxVal);
                      return Column(
                        children: [
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3.5,
                              thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6),
                              overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 16),
                              activeTrackColor: AppTheme.primaryDark,
                              inactiveTrackColor: Color(0xFF81C784),
                              thumbColor: AppTheme.primaryDark,
                              overlayColor: Color(0x2A2E7D32),
                            ),
                            child: Slider(
                              min: 0,
                              max: maxVal,
                              value: val,
                              onChanged: (v) => _svc.player.seek(
                                  Duration(milliseconds: v.toInt())),
                            ),
                          ),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 26),
                            child: Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                              children: [
                                Text(_fmt(pos),
                                    style: const TextStyle(
                                        color: AppTheme.primary,
                                        fontSize: 11)),
                                Text(
                                  "${(idx >= 0 ? idx : 0) + 1} / ${widget.songs.length}",
                                  style: const TextStyle(
                                      color: AppTheme.primary, fontSize: 11),
                                ),
                                Text(_fmt(total),
                                    style: const TextStyle(
                                        color: AppTheme.primary,
                                        fontSize: 11)),
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
                        IconButton(
                          iconSize: 24,
                          icon: Icon(Icons.shuffle_rounded,
                              color: _shuffle
                                  ? AppTheme.primaryDark
                                  : AppTheme.primary),
                          onPressed: () =>
                              setState(() => _shuffle = !_shuffle),
                        ),
                        // Previous
                        IconButton(
                          iconSize: 36,
                          icon: const Icon(Icons.skip_previous_rounded,
                              color: AppTheme.primaryDark),
                          onPressed: _svc.previous,
                        ),
                        // Play / Pause
                        StreamBuilder<PlayerState>(
                          stream: _svc.player.playerStateStream,
                          builder: (_, s) {
                            final playing = s.data?.playing ?? false;
                            return GestureDetector(
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
                                      color: AppTheme.primaryDark.withOpacity(0.35),
                                      blurRadius: 20,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  playing
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  color: Colors.white,
                                  size: 40,
                                ),
                              ),
                            );
                          },
                        ),
                        // Next
                        IconButton(
                          iconSize: 36,
                          icon: const Icon(Icons.skip_next_rounded,
                              color: AppTheme.primaryDark),
                          onPressed: _svc.next,
                        ),
                        // Repeat
                        IconButton(
                          iconSize: 24,
                          icon: Icon(Icons.repeat_rounded,
                              color: _repeat
                                  ? AppTheme.primaryDark
                                  : AppTheme.primary),
                          onPressed: () =>
                              setState(() => _repeat = !_repeat),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 6),

                  // ── Seek -10 / +10 ──
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton.icon(
                        style: TextButton.styleFrom(
                            foregroundColor: AppTheme.primary),
                        onPressed: () =>
                            _svc.seekBy(const Duration(seconds: -10)),
                        icon: const Icon(Icons.replay_10_rounded, size: 22),
                        label: const Text(""),
                      ),
                      const SizedBox(width: 32),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                            foregroundColor: AppTheme.primary),
                        onPressed: () =>
                            _svc.seekBy(const Duration(seconds: 10)),
                        icon: const Icon(Icons.forward_10_rounded, size: 22),
                        label: const Text(""),
                      ),
                    ],
                  ),
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
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final result = <Song>[];
    for (final s in widget.songs) {
      if (await AudioCacheService.isDownloaded(s.fileUrl)) result.add(s);
    }
    final sz = await AudioCacheService.totalSizeMB();
    if (mounted) setState(() {
      _local = result;
      _sizeMB = sz;
      _loading = false;
    });
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
              child: const Text("Cancel")),
          ElevatedButton(
            style:
                ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Clear"),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final s in _local) await AudioCacheService.deleteLocal(s.fileUrl);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.cream,
      appBar: AppBar(
        title: const Text("Downloads",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        elevation: 0,
        automaticallyImplyLeading: false,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
                colors: [AppTheme.primaryDark, AppTheme.primary]),
          ),
        ),
        actions: [
          if (_local.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined,
                  color: Colors.white),
              onPressed: _clearAll,
              tooltip: "Clear all",
            ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primary))
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
                          onRemove: () async {
                            await AudioCacheService.deleteLocal(_local[i].fileUrl);
                            _load();
                          },
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
              colors: [Color(0xFF33691E), Color(0xFF558B2F)]),
        ),
        child: Row(
          children: [
            const Icon(Icons.download_done_rounded,
                color: Colors.white, size: 30),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("${_local.length} songs saved offline",
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold)),
                Text("${_sizeMB.toStringAsFixed(1)} MB used",
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12)),
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
            Text("No downloads yet",
                style: TextStyle(fontSize: 16, color: Colors.grey)),
            SizedBox(height: 8),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                "Tap the  icon on any song to save it for offline listening",
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
  const _LocalCard(
      {required this.song, required this.onPlay, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 6,
              offset: const Offset(0, 3))
        ],
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: Container(
          height: 46,
          width: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: const LinearGradient(
                colors: [AppTheme.primary, AppTheme.primaryLight]),
          ),
          child: const Icon(Icons.music_note_rounded,
              color: Colors.white, size: 22),
        ),
        title: Text(
          song.title.replaceAll(RegExp(r'\.[^.]+$'), ''),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
        subtitle: const Row(
          children: [
            Icon(Icons.offline_bolt_rounded,
                size: 12, color: AppTheme.primary),
            SizedBox(width: 4),
            Text("Available offline",
                style: TextStyle(fontSize: 12, color: AppTheme.primary)),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.play_arrow_rounded,
                  color: AppTheme.primary, size: 26),
              onPressed: () => onPlay(song),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline,
                  color: Colors.red, size: 20),
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
  const SettingsPage({
    super.key,
    required this.onUpdate,
    required this.songs,
    required this.onSongsUpdated,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _loggedIn = false;

  @override
  void initState() {
    super.initState();
    AuthPrefs.isLoggedIn().then((v) => setState(() => _loggedIn = v));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.cream,
      appBar: AppBar(
        title: const Text("Settings & About",
            style:
                TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        elevation: 0,
        automaticallyImplyLeading: false,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
                colors: [AppTheme.primaryDark, AppTheme.primary]),
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
            "Clear Song List Cache",
            "Force re-fetch song list on next launch",
            Colors.orange,
            () async {
              await SongCacheService.clear();
              _snack("Cache cleared", AppTheme.primary);
            },
          ),

          _section("ACCOUNT"),
          if (!_loggedIn)
            _tile(Icons.login_rounded, "Admin Login",
                "Manage uploads and content", AppTheme.primary, () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => LoginPage(
                    songs: allSongs,
                    onLogin: () => setState(() => _loggedIn = true),
                  ),
                ),
              );
              final v = await AuthPrefs.isLoggedIn();
              setState(() => _loggedIn = v);
            }),
          if (_loggedIn) ...[
            _tile(
              Icons.admin_panel_settings_rounded,
              "Admin Panel",
              "Upload and manage audio content",
              AppTheme.primaryDark,
              () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AdminPanel(
                      songs: widget.songs,
                      onSongsUpdated: widget.onSongsUpdated,
                    ),
                  ),
                );
              },
            ),
            _tile(Icons.logout_rounded, "Logout", "Sign out of admin account",
                Colors.red, () async {
              await AuthPrefs.logout();
              setState(() => _loggedIn = false);
              widget.onUpdate();
              _snack("Logged out successfully", Colors.grey.shade700);
            }),
          ],

          _section("ABOUT"),
          _tile(
            Icons.info_outline_rounded,
            "App Version",
            "Farm Radio v2.0 — Production Release",
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

  void _snack(String msg, Color bg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: bg,
      behavior: SnackBarBehavior.floating,
    ));
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
                  Text("ANGRAU Farm Radio",
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.bold)),
                  SizedBox(height: 4),
                  Text("Agricultural Advisory Platform",
                      style:
                          TextStyle(color: Colors.white70, fontSize: 12)),
                  SizedBox(height: 8),
                  Text("Version 2.0",
                      style:
                          TextStyle(color: Colors.white60, fontSize: 11)),
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
  ) =>
      Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: Colors.white,
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 6,
                offset: const Offset(0, 2))
          ],
        ),
        child: ListTile(
          leading: Container(
            height: 42,
            width: 42,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: color.withOpacity(0.12),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          title: Text(title,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 14)),
          subtitle:
              Text(sub, style: const TextStyle(fontSize: 12)),
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
          border: Border.all(color: AppTheme.primary.withOpacity(0.3)),
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
              style: TextStyle(
                  fontSize: 13, color: AppTheme.textMid, height: 1.6),
            ),
          ],
        ),
      );
}

// ============================================================
// ADMIN PANEL (with drag-drop reorder)
// ============================================================
class AdminPanel extends StatefulWidget {
  final List<Song> songs;
  final void Function(List<Song>) onSongsUpdated;
  const AdminPanel(
      {super.key, required this.songs, required this.onSongsUpdated});

  @override
  State<AdminPanel> createState() => _AdminPanelState();
}

class _AdminPanelState extends State<AdminPanel> {
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

  Future<void> _upload() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result == null) return;

    _showLoading("Uploading audio...");
    try {
      await ApiService.uploadSong(result.files.single.path!);
      final updated = await ApiService.fetchSongs();
      await SongCacheService.save(updated);
      allSongs = updated;
      if (!mounted) return;
      Navigator.pop(context); // close loading
      setState(() => _songs = List.from(updated));
      widget.onSongsUpdated(updated);
      await _showSuccess("Audio uploaded successfully!");
    } catch (e) {
      if (mounted) Navigator.pop(context);
      _snack("Upload failed: $e", Colors.red);
    }
  }

  Future<void> _delete(Song song) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("Delete Audio"),
        content: Text(
            "Delete \"${song.title.replaceAll(RegExp(r'\.[^.]+$'), '')}\"?\n\nThis removes it from the app."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("Cancel")),
          ElevatedButton(
            style:
                ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await ApiService.deleteSong(song.id);
      final updated = await ApiService.fetchSongs();
      await SongCacheService.save(updated);
      allSongs = updated;
      setState(() => _songs = List.from(updated));
      widget.onSongsUpdated(updated);
    } catch (e) {
      _snack("Delete failed: $e", Colors.red);
    }
  }

  Future<void> _saveOrder() async {
    setState(() => _savingOrder = true);
    try {
      await ApiService.reorderSongs(_songs);
      await SongCacheService.save(_songs);
      allSongs = _songs;
      widget.onSongsUpdated(_songs);
      _snack("Order saved!", AppTheme.primary);
    } catch (e) {
      _snack("Could not save order: $e", Colors.red);
    }
    if (mounted) setState(() => _savingOrder = false);
  }

  void _showLoading(String msg) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
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
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: const Icon(Icons.check_circle_rounded,
            color: AppTheme.primary, size: 52),
        content: Text(msg, textAlign: TextAlign.center),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("OK"))
        ],
      ),
    );
  }

  void _snack(String msg, Color bg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: bg,
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.cream,
      appBar: AppBar(
        title: const Text("Admin Panel",
            style: TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold)),
        elevation: 0,
        automaticallyImplyLeading: false,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
                colors: [AppTheme.earth, Color(0xFFA1887F)]),
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
                          color: Colors.white, strokeWidth: 2),
                    ),
                  )
                : TextButton.icon(
                    icon: const Icon(Icons.save_rounded,
                        color: Colors.white, size: 18),
                    label: const Text("Save Order",
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600)),
                    onPressed: _saveOrder,
                  ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _upload,
        icon: const Icon(Icons.upload_rounded),
        label: const Text("Upload Audio",
            style: TextStyle(fontWeight: FontWeight.w600)),
        backgroundColor: AppTheme.earth,
      ),
      body: _songs.isEmpty
          ? _empty()
          : Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  color: Colors.white,
                  child: Row(
                    children: [
                      const Icon(Icons.drag_indicator_rounded,
                          color: Colors.grey, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        "${_songs.length} audios – drag to reorder, tap Save Order",
                        style: const TextStyle(
                            color: Colors.grey, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 100),
                    itemCount: _songs.length,
                    onReorder: (oldIdx, newIdx) {
                      setState(() {
                        if (newIdx > oldIdx) newIdx--;
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
            const Icon(Icons.audio_file_outlined,
                size: 72, color: Colors.grey),
            const SizedBox(height: 16),
            const Text("No audio uploaded yet",
                style: TextStyle(fontSize: 16, color: Colors.grey)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _upload,
              icon: const Icon(Icons.upload_rounded),
              label: const Text("Upload First Audio"),
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.earth,
                  foregroundColor: Colors.white),
            ),
          ],
        ),
      );
}

class _AdminCard extends StatelessWidget {
  final Song song;
  final int index;
  final VoidCallback onDelete;
  const _AdminCard(
      {super.key,
      required this.song,
      required this.index,
      required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 6,
              offset: const Offset(0, 3))
        ],
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
                    fontSize: 13),
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
                    colors: [Color(0xFF558B2F), Color(0xFF8BC34A)]),
              ),
              child: const Icon(Icons.music_note_rounded,
                  color: Colors.white, size: 22),
            ),
          ],
        ),
        title: Text(
          song.title.replaceAll(RegExp(r'\.[^.]+$'), ''),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style:
              const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
        subtitle: const Text("Audio Advisory",
            style: TextStyle(fontSize: 12, color: Colors.grey)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.delete_outline,
                  color: Colors.red, size: 22),
              onPressed: onDelete,
            ),
            const Icon(Icons.drag_handle_rounded, color: Colors.grey),
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
  final List<Song> songs;
  final VoidCallback onLogin;
  const LoginPage({super.key, required this.songs, required this.onLogin});

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
    setState(() {
      _loading = true;
      _error = null;
    });
    await Future.delayed(const Duration(milliseconds: 500));
    if (_userCtrl.text.trim() == "Pradeep" &&
        _passCtrl.text == "Pradeep@123") {
      await AuthPrefs.setLoggedIn(true);
      widget.onLogin();
      if (mounted) Navigator.pop(context, true);
    } else {
      setState(() {
        _error = "Invalid username or password.";
        _loading = false;
      });
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
      body: KeyboardVisibilityBuilder(
        builder: (ctx, _) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              children: [
                // Header gradient
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(24, 56, 24, 40),
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
                        "ANGRAU Farm Radio",
                        style:
                            TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                    ],
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.all(24),
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
                              const Icon(Icons.error_outline,
                                  color: Colors.red, size: 18),
                              const SizedBox(width: 8),
                              Text(_error!,
                                  style: const TextStyle(
                                      color: Colors.red, fontSize: 13)),
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
                                color: Colors.black.withOpacity(0.07),
                                blurRadius: 8,
                                offset: const Offset(0, 3))
                          ],
                        ),
                        child: TextField(
                          controller: _userCtrl,
                          decoration: const InputDecoration(
                            hintText: "Username",
                            prefixIcon: Icon(Icons.person_rounded,
                                color: AppTheme.primary),
                            border: InputBorder.none,
                            contentPadding:
                                EdgeInsets.symmetric(vertical: 16),
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
                                color: Colors.black.withOpacity(0.07),
                                blurRadius: 8,
                                offset: const Offset(0, 3))
                          ],
                        ),
                        child: TextField(
                          controller: _passCtrl,
                          obscureText: _obscure,
                          onSubmitted: (_) => _login(),
                          decoration: InputDecoration(
                            hintText: "Password",
                            prefixIcon: const Icon(Icons.lock_rounded,
                                color: AppTheme.primary),
                            suffixIcon: IconButton(
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
                            contentPadding:
                                const EdgeInsets.symmetric(vertical: 16),
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
                                borderRadius: BorderRadius.circular(14)),
                          ),
                          child: _loading
                              ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2),
                                )
                              : const Text("Login",
                                  style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
