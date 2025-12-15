import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:file_picker/file_picker.dart';

void main() {
  runApp(const FarmRadioApp());
}

class FarmRadioApp extends StatelessWidget {
  const FarmRadioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Farm Radio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        primaryColor: Colors.green,
        scaffoldBackgroundColor: const Color(0xFFF4FBF4),
        fontFamily: 'Roboto',
      ),
      home: SplashScreen(),
    );
  }
}

List<Song> allSongs = [];

class Song {
  final int id;
  final String title;
  final String fileUrl;

  Song({required this.id, required this.title, required this.fileUrl});

  factory Song.fromJson(Map<String, dynamic> json) {
    return Song(
      id: json['id'],
      title: json['title'],
      fileUrl: json['file_url'],
    );
  }
}

class MainShell extends StatefulWidget {
  final List<Song> songs;
  const MainShell({required this.songs});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int index = 0; // 0 = Home, 1 = Player, 2 = Admin
  int currentSongIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: [
        // ================= HOME =================
        HomePage(
          songs: widget.songs,
          onPlay: (song) {
            final i = widget.songs.indexOf(song);
            if (i == -1) return;

            setState(() {
              currentSongIndex = i;
              index = 1; // 🔥 Open PlayerPage
            });
          },
        ),

        // ================= PLAYER (FULL SCREEN) =================
        PlayerPage(
          songs: widget.songs,
          currentIndex: currentSongIndex,
          onIndexChanged: (i) {
            setState(() => currentSongIndex = i);
          },
          onClose: () {
            setState(() => index = 0); // 🔥 Back to Home
          },
        ),

        // ================= ADMIN =================
        AdminPanel(songs: widget.songs),
      ][index],

      // ================= BOTTOM NAV =================
      // 🔥 Hidden ONLY when PlayerPage is active
      bottomNavigationBar: index == 1
          ? null
          : BottomNavigationBar(
              currentIndex: index,
              onTap: (i) => setState(() => index = i),
              items: const [
                BottomNavigationBarItem(icon: Icon(Icons.home), label: "Home"),
                BottomNavigationBarItem(
                  icon: Icon(Icons.play_circle),
                  label: "Player",
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.admin_panel_settings),
                  label: "Admin",
                ),
              ],
            ),
    );
  }
}

class SplashScreen extends StatefulWidget {
  @override
  _SplashScreenState createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final songs = await ApiService.fetchSongs();
    allSongs = songs; // 🔴 IMPORTANT
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => MainShell(songs: songs)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(height: 35),

                /// --- University Heading Text ---
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
                SizedBox(height: 6),
                Text(
                  "LAM, GUNTUR, ANDHRA PRADESH",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.green.shade800,
                  ),
                ),

                SizedBox(height: 50),

                /// --- Logo ---
                Image.asset(
                  "assets/images/angrauicon.png",
                  width: MediaQuery.of(context).size.width * 0.45,
                  fit: BoxFit.contain,
                ),
                SizedBox(height: 10),
                Text(
                  "Farm Radio",
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.green.shade800,
                  ),
                ),

                SizedBox(height: 10),

                /// Developed By
                Text(
                  "Developed by",
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.green.shade800,
                  ),
                ),

                SizedBox(height: 12),

                /// Developer card
                Container(
                  width: MediaQuery.of(context).size.width * 0.93,
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(color: Colors.green.shade800, width: 2),
                  ),
                  child: Column(
                    children: [
                      Text(
                        "Dr. P.B. Pradeep Kumar\nCoordinator & Scientist (T.O.T) DAATTC, PADERU, A.S.R. District.A.P.",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 10),
                      Text(
                        "Dr. A. Appalaswamy\nAssociate Director of Research, High Altitude...",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 10),
                      Text(
                        "Dr. G. Sivanarayana\nDirector of Extension, ANGRAU",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),

                SizedBox(height: 50),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ApiService {
  static const baseUrl = "http://13.203.219.206:8000";

  static Future<List<Song>> fetchSongs() async {
    final res = await http.get(Uri.parse("$baseUrl/songs/"));
    final List data = jsonDecode(res.body);
    return data.map((e) => Song.fromJson(e)).toList();
  }

  static Future<void> deleteSong(int id) async {
    await http.delete(Uri.parse("$baseUrl/songs/$id/"));
  }

  static Future<void> uploadSong(String path) async {
    final request = http.MultipartRequest(
      "POST",
      Uri.parse("$baseUrl/songs/upload/"),
    );

    request.files.add(await http.MultipartFile.fromPath("file", path));
    await request.send();
  }
}

class HomePage extends StatelessWidget {
  final List<Song> songs;
  final Function(Song) onPlay;
  const HomePage({required this.songs, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FC),
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(64),
        child: AppBar(
          elevation: 0,
          automaticallyImplyLeading: false,
          flexibleSpace: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.orangeAccent, // soft green
                  Colors.orangeAccent, // calm blue
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          titleSpacing: 0,
          title: Row(
            children: [
              const SizedBox(width: 16),

              // App icon
              Container(
                height: 50,
                width: 50,
                //   padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  //       color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Image.asset(
                  "assets/images/miniicon.png",
                  fit: BoxFit.fill,
                ),
              ),

              const SizedBox(width: 12),

              // App title
              Center(
                child: const Text(
                  "Angruv Farm Radio",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          ),

          actions: [
            IconButton(
              icon: const Icon(Icons.admin_panel_settings_outlined),
              color: Colors.white,
              tooltip: "Admin Panel",
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => AdminPanel(songs: songs)),
                );
              },
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 90),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ================= TOP BAR =================
                  SizedBox(height: 30),

                  // ================= CAROUSEL =================
                  AutoCarousel(songs: songs, onSelect: onPlay),

                  const SizedBox(height: 10),

                  // ================= SONG LIST =================
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      "Recommended",
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),

                  const SizedBox(height: 10),

                  ...songs.map((song) => _songRectCard(song, onPlay)),

                  const SizedBox(height: 24),

                  // ================= CATEGORIES =================
                ],
              ),
            ),

            // ================= MINI PLAYER =================
          ],
        ),
      ),
      // 🔥 FIXED AREA
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [_miniPlayer(context, songs, onPlay)],
      ),
    );
  }

  Widget _miniPlayer(
    BuildContext context,
    List<Song> songs,
    Function(Song) onPlay,
  ) {
    if (songs.isEmpty) return const SizedBox.shrink();

    return InkWell(
      onTap: () => onPlay(songs.first),
      child: Container(
        height: 58,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: Colors.blueAccent,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: const [
            Icon(Icons.music_note, color: Colors.white),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                "Now Playing – Farm Advisory",
                style: TextStyle(color: Colors.white, fontSize: 15),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.pause, color: Colors.white),
            SizedBox(width: 12),
          ],
        ),
      ),
    );
  }

  Widget _bottomNav() {
    return BottomNavigationBar(
      currentIndex: 0,
      items: const [
        BottomNavigationBarItem(icon: Icon(Icons.home), label: "Home"),
        BottomNavigationBarItem(icon: Icon(Icons.play_circle), label: "Player"),
        BottomNavigationBarItem(
          icon: Icon(Icons.admin_panel_settings),
          label: "Admin",
        ),
      ],
    );
  }

  // ================= SONG CARD =================
  Widget _songRectCard(Song song, Function(Song) onSelect) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Container(
        height: 76,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Colors.white,
          boxShadow: const [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 8,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),

            // ===== ICON BLOCK =====
            Container(
              height: 52,
              width: 52,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: LinearGradient(
                  colors: [Colors.orange.shade400, Colors.blue.shade400],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: const Icon(
                Icons.music_note_rounded,
                color: Colors.white,
                size: 28,
              ),
            ),

            const SizedBox(width: 14),

            // ===== SONG DETAILS =====
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Songs",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "${"Songs"} • ${"Songs"}",
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),

            // ===== PLAY BUTTON =====
            IconButton(
              icon: Container(
                height: 34,
                width: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.blue.shade50,
                ),
                child: const Icon(Icons.play_arrow_rounded, color: Colors.blue),
              ),
              onPressed: () => onSelect(song),
            ),

            // ===== MORE OPTIONS =====
            IconButton(
              icon: const Icon(Icons.more_vert, color: Colors.grey),
              onPressed: () {
                // TODO: open bottom sheet (Low / High / Full screen)
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _categoryChip(String label) {
    return Container(
      margin: const EdgeInsets.only(right: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.orange.shade100,
      ),
      child: Center(child: Text(label)),
    );
  }
}

class PlayerPage extends StatefulWidget {
  final List<Song> songs;
  final int currentIndex;
  final ValueChanged<int> onIndexChanged;
  final VoidCallback onClose;

  const PlayerPage({
    super.key,
    required this.songs,
    required this.currentIndex,
    required this.onIndexChanged,
    required this.onClose,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final AudioPlayer _player = AudioPlayer();

  Song get currentSong => widget.songs[widget.currentIndex];

  @override
  void initState() {
    super.initState();
    if (widget.songs.isNotEmpty) {
      _playCurrent();
    }
  }

  @override
  void didUpdateWidget(covariant PlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      _playCurrent();
    }
  }

  Future<void> _playCurrent() async {
    try {
      await _player.stop();
      await _player.setUrl(currentSong.fileUrl);
      await _player.play();
    } catch (e) {
      debugPrint("Audio error: $e");
    }
  }

  void _nextSong() {
    if (widget.currentIndex < widget.songs.length - 1) {
      widget.onIndexChanged(widget.currentIndex + 1);
    }
  }

  void _previousSong() {
    if (widget.currentIndex > 0) {
      widget.onIndexChanged(widget.currentIndex - 1);
    }
  }

  void _seekBy(Duration offset) {
    final pos = _player.position;
    final total = _player.duration ?? Duration.zero;
    final target = pos + offset;

    if (target < Duration.zero) {
      _player.seek(Duration.zero);
    } else if (target > total) {
      _player.seek(total);
    } else {
      _player.seek(target);
    }
  }

  String _format(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return "$m:$s";
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.songs.isEmpty) {
      return const Scaffold(body: Center(child: Text("No songs available")));
    }

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF6DD5FA), Color(0xFF2980B9)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // TOP BAR
              Row(
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.keyboard_arrow_down,
                      color: Colors.white,
                    ),
                    onPressed: widget.onClose, // ✅ CORRECT EXIT
                  ),
                  const Spacer(),
                  const Icon(Icons.more_vert, color: Colors.white),
                  const SizedBox(width: 12),
                ],
              ),

              const SizedBox(height: 30),

              // ALBUM ART
              Container(
                height: 260,
                width: 260,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 20,
                      offset: Offset(0, 10),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Image.asset(
                    "assets/images/soil.jpg",
                    fit: BoxFit.cover,
                  ),
                ),
              ),

              const SizedBox(height: 30),

              // TITLE
              Text(
                currentSong.title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 6),

              const Text(
                "ANGRAU Scientist • Crop Advisory",
                style: TextStyle(color: Colors.white70),
              ),

              const SizedBox(height: 30),

              // SEEK BAR
              StreamBuilder<Duration>(
                stream: _player.positionStream,
                builder: (_, snap) {
                  final pos = snap.data ?? Duration.zero;
                  final total = _player.duration ?? Duration.zero;

                  return Column(
                    children: [
                      Slider(
                        min: 0,
                        max: total.inSeconds.toDouble().clamp(
                          1,
                          double.infinity,
                        ),
                        value: pos.inSeconds.toDouble().clamp(
                          0,
                          total.inSeconds.toDouble(),
                        ),
                        onChanged: (v) =>
                            _player.seek(Duration(seconds: v.toInt())),
                        activeColor: Colors.white,
                        inactiveColor: Colors.white30,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _format(pos),
                              style: const TextStyle(color: Colors.white70),
                            ),
                            Text(
                              _format(total),
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),

              const Spacer(),

              // CONTROLS
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    iconSize: 34,
                    color: Colors.white,
                    icon: const Icon(Icons.skip_previous),
                    onPressed: _previousSong,
                  ),
                  IconButton(
                    iconSize: 30,
                    color: Colors.white,
                    icon: const Icon(Icons.replay_10),
                    onPressed: () => _seekBy(const Duration(seconds: -10)),
                  ),
                  Container(
                    height: 80,
                    width: 80,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                    ),
                    child: StreamBuilder<PlayerState>(
                      stream: _player.playerStateStream,
                      builder: (_, s) {
                        final playing = s.data?.playing ?? false;
                        return IconButton(
                          iconSize: 44,
                          icon: Icon(
                            playing ? Icons.pause : Icons.play_arrow,
                            color: Colors.green,
                          ),
                          onPressed: () =>
                              playing ? _player.pause() : _player.play(),
                        );
                      },
                    ),
                  ),
                  IconButton(
                    iconSize: 30,
                    color: Colors.white,
                    icon: const Icon(Icons.forward_10),
                    onPressed: () => _seekBy(const Duration(seconds: 10)),
                  ),
                  IconButton(
                    iconSize: 34,
                    color: Colors.white,
                    icon: const Icon(Icons.skip_next),
                    onPressed: _nextSong,
                  ),
                ],
              ),

              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  // ---------- PLACEHOLDER FUNCTIONS (FOR FUTURE) ----------
  void openLikedSongs() {}
  void openDownloads() {}
  void openPlaylists() {}
  void openAboutApp() {}
  void openContact() {}
  void openSettings() {}

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---------------- HEADER ----------------
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: const LinearGradient(
                  colors: [
                    Color.fromARGB(255, 229, 159, 238),
                    Color.fromARGB(255, 248, 213, 109),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Row(
                children: const [
                  Icon(Icons.library_music, color: Colors.white, size: 34),
                  SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Your Library",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        "Saved & personalized content",
                        style: TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // ---------------- QUICK ACTIONS ----------------
            const Text(
              "Quick Access",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 14),

            GridView.count(
              crossAxisCount: size.width > 600 ? 4 : 2,
              crossAxisSpacing: 14,
              mainAxisSpacing: 14,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _libraryTile(
                  icon: Icons.favorite,
                  title: "Liked Audios",
                  color: const Color(0xFFE57373),
                  onTap: openLikedSongs,
                ),
                _libraryTile(
                  icon: Icons.download,
                  title: "Downloads",
                  color: const Color(0xFF64B5F6),
                  onTap: openDownloads,
                ),
                _libraryTile(
                  icon: Icons.queue_music,
                  title: "Playlists",
                  color: const Color(0xFFBA68C8),
                  onTap: openPlaylists,
                ),
                _libraryTile(
                  icon: Icons.settings,
                  title: "Settings",
                  color: const Color(0xFFFFB74D),
                  onTap: openSettings,
                ),
              ],
            ),

            const SizedBox(height: 30),

            // ---------------- INFORMATION SECTION ----------------
            const Text(
              "About Farm Radio",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),

            _infoCard(
              icon: Icons.agriculture,
              title: "What is Farm Radio?",
              subtitle:
                  "A digital agriculture audio platform delivering expert farming knowledge in simple audio form.",
            ),

            _infoCard(
              icon: Icons.cloud,
              title: "Future Enhancements",
              subtitle:
                  "Cloud-based streaming, live farm radio, expert uploads, and personalized advisories.",
            ),

            _infoCard(
              icon: Icons.school,
              title: "Powered by Knowledge",
              subtitle:
                  "Designed for farmers, students, and extension workers using verified agricultural content.",
            ),

            const SizedBox(height: 20),

            // ---------------- FOOTER ACTIONS ----------------
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: openAboutApp,
                    icon: const Icon(Icons.info_outline),
                    label: const Text("About App"),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: openContact,
                    icon: const Icon(Icons.contact_mail_outlined),
                    label: const Text("Contact"),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 30),

            Center(
              child: Text(
                "Farm Radio • Version 1.0",
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- TILE WIDGET ----------------
  Widget _libraryTile({
    required IconData icon,
    required String title,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: color.withOpacity(0.15),
          border: Border.all(color: color.withOpacity(0.4)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: color,
              child: Icon(icon, color: Colors.white, size: 28),
            ),
            const SizedBox(height: 10),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  // ---------------- INFO CARD ----------------
  Widget _infoCard({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.green.withOpacity(0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: Colors.green.shade100,
            child: Icon(icon, color: Colors.green.shade800),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AutoCarousel extends StatefulWidget {
  final List<Song> songs;
  final Function(Song) onSelect;

  const AutoCarousel({super.key, required this.songs, required this.onSelect});

  @override
  State<AutoCarousel> createState() => _AutoCarouselState();
}

class _AutoCarouselState extends State<AutoCarousel> {
  late final PageController _controller;
  int _currentIndex = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _controller = PageController(viewportFraction: 0.65);

    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!_controller.hasClients) return;

      _currentIndex++;
      if (_currentIndex >= widget.songs.length) {
        _currentIndex = 0;
      }

      _controller.animateToPage(
        _currentIndex,
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 180,
      child: PageView.builder(
        controller: _controller,
        itemCount: widget.songs.length,
        itemBuilder: (context, i) {
          final song = widget.songs[i];

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: GestureDetector(
              onTap: () => widget.onSelect(song),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  image: DecorationImage(
                    image: AssetImage(
                      "assets/images/soil.jpg",
                    ), // 🔥 image fixed to card
                    fit: BoxFit.cover,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 10,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    // ===== DARK OVERLAY FOR TEXT READABILITY =====
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        gradient: const LinearGradient(
                          colors: [Colors.transparent, Colors.black87],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                      ),
                    ),

                    // ===== TEXT =====
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Songs",
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            "Songs",
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // ===== PLAY BUTTON =====
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: Container(
                        height: 42,
                        width: 42,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.blue,
                          size: 26,
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

class AdminPanel extends StatelessWidget {
  final List<Song> songs;
  const AdminPanel({required this.songs});

  Future<void> uploadSong(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(type: FileType.audio);
    if (result == null) return;

    await ApiService.uploadSong(result.files.single.path!);
    final updated = await ApiService.fetchSongs();
    allSongs = updated;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => MainShell(songs: updated)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () => uploadSong(context),
        child: const Icon(Icons.add),
      ),
      body: ListView.builder(
        itemCount: songs.length,
        itemBuilder: (_, i) {
          return ListTile(
            title: Text(songs[i].title),
            trailing: IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () async {
                await ApiService.deleteSong(songs[i].id);
                final updated = await ApiService.fetchSongs();
                allSongs = updated;

                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (_) => MainShell(songs: updated)),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
