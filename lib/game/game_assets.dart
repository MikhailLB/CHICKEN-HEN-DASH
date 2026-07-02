import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

class GameAssets {
  GameAssets._();

  static final GameAssets _instance = GameAssets._();
  factory GameAssets() => _instance;

  bool _loaded = false;
  bool get loaded => _loaded;

  late ui.Image chickens;
  late ui.Image carRed;
  late ui.Image carBlue;
  late ui.Image bus;
  late ui.Image tractor;
  late ui.Image grass;
  late ui.Image road;
  late ui.Image water;
  late ui.Image pavement;
  late ui.Image log;
  late ui.Image waterlily;
  late ui.Image rock;
  late ui.Image hay;
  late ui.Image fence;

  Future<void> load() async {
    if (_loaded) return;
    final results = await Future.wait([
      _load('assets/chikens.webp'),
      _load('assets/carred.webp'),
      _load('assets/bluecar.webp'),
      _load('assets/yellowcar.webp'),
      _load('assets/tractor.webp'),
      _load('assets/grass.webp'),
      _load('assets/road.webp'),
      _load('assets/water.webp'),
      _load('assets/pavet.webp'),
      _load('assets/log .webp'),
      _load('assets/waterlily.webp'),
      _load('assets/rock.webp'),
      _load('assets/hay.webp'),
      _load('assets/fence.webp'),
    ]);
    chickens = results[0];
    carRed = results[1];
    carBlue = results[2];
    bus = results[3];
    tractor = results[4];
    grass = results[5];
    road = results[6];
    water = results[7];
    pavement = results[8];
    log = results[9];
    waterlily = results[10];
    rock = results[11];
    hay = results[12];
    fence = results[13];
    _loaded = true;
  }

  Future<ui.Image> _load(String path) async {
    final data = await rootBundle.load(path);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    return frame.image;
  }
}
