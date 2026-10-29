package com.example.farmradio

import com.ryanheise.audioservice.AudioServiceActivity

// AudioServiceActivity (not FlutterActivity) lets just_audio_background keep
// playing with a media notification while the app is in the background.
class MainActivity : AudioServiceActivity()
