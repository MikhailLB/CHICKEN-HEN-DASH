import 'dart:math';
import 'dart:ui' as ui;
import 'dart:ui' show Rect;

import 'game_assets.dart';

enum RowKind { grass, pavement, road, water }

enum VehicleType { car, truck, bus, tractor }

class VehicleSprite {
  const VehicleSprite({
    required this.image,
    required this.widthCells,
    required this.defaultFacing,
    required this.canvasCells,
    this.sourceCrop,
  });
  final ui.Image image;
  // Collision width, matching the visible body of the sprite (transparent
  // padding excluded).
  final double widthCells;
  final int defaultFacing; // 1 = right, -1 = left
  // Size of the (square) sprite canvas expressed in row-heights (cells).
  // Painted with the source aspect preserved so the sprite is not stretched.
  final double canvasCells;
  // Optional crop of the source image used instead of the full canvas.
  // When set, the sprite is drawn using this rect's aspect and sized so its
  // width matches `widthCells` (height derived from the crop aspect).
  final Rect? sourceCrop;
}

enum ObstacleKind { hay, rock, fence }

class Obstacle {
  Obstacle({
    required this.col,
    required this.image,
    required this.kind,
    this.spanCells = 1,
    this.sourceCrop,
  });
  final int col;
  final ui.Image image;
  final ObstacleKind kind;
  final int spanCells;
  // Tight crop around the painted body inside the source PNG (transparent
  // padding removed). If null, the whole image is used.
  final Rect? sourceCrop;

  bool blocks(int c) {
    final half = spanCells ~/ 2;
    if (spanCells.isOdd) {
      return c >= col - half && c <= col + half;
    }
    return c >= col && c < col + spanCells;
  }
}

// Precise painted-body crops (extracted via `PIL.getbbox()` from each source
// PNG). Using these keeps the visible sprite width equal to the collision
// footprint — no more empty space between the picture and the hitbox.
class ObstacleCrops {
  static const Rect fence = Rect.fromLTRB(128, 219, 384, 293); // 256x74
  static const Rect hay = Rect.fromLTRB(128, 129, 384, 383); // 256x254
  static const Rect rock = Rect.fromLTRB(134, 128, 378, 384); // 244x256
}

class MovingEntity {
  MovingEntity({
    required this.xCells,
    required this.widthCells,
    required this.speed, // cells per second (signed)
  });
  double xCells;
  final double widthCells;
  final double speed;

  double get leftCell => xCells;
  double get rightCell => xCells + widthCells;
}

class RowData {
  RowData({
    required this.index,
    required this.kind,
    this.obstacles = const [],
    this.direction = 0,
    this.speed = 0,
    this.vehicle,
    this.spawnInterval = 0,
    this.isCheckpoint = false,
  });

  final int index;
  final RowKind kind;
  final List<Obstacle> obstacles;
  final int direction; // -1 or 1 for road/water
  final double speed; // absolute cells/sec
  final VehicleSprite? vehicle;
  final double spawnInterval;
  final bool isCheckpoint;

  double spawnTimer = 0;
  List<MovingEntity> movers = [];
}

class Chicken {
  Chicken({required this.col, required this.row})
      : xPxOffset = 0,
        alive = true,
        hopping = false,
        hopProgress = 0,
        hopFromCol = col,
        hopFromRow = row,
        hopToCol = col,
        hopToRow = row,
        ridingLog = null;

  int col;
  int row;
  double xPxOffset; // horizontal pixel offset from grid (when riding log)

  bool alive;
  bool hopping;
  double hopProgress;
  int hopFromCol;
  int hopFromRow;
  int hopToCol;
  int hopToRow;
  double hopFromOffsetPx = 0;
  double hopToOffsetPx = 0;

  MovingEntity? ridingLog;

  // Bump animation: when a hop is blocked, briefly nudge the chicken toward
  // the obstacle so the player feels the block. Direction is in (col, row)
  // deltas; progress runs 0..1.
  double bumpDx = 0;
  double bumpDy = 0;
  double bumpProgress = 0;
  bool get bumping => bumpProgress > 0 && bumpProgress < 1;
}

class GameState {
  GameState({required this.cols});
  final int cols;
  final Random _rng = Random();

  final Map<int, RowData> rows = {};
  int minRowGenerated = 0;
  int maxRowGenerated = 0;

  late Chicken chicken;

  int maxRowReached = 0;
  double multiplier = 1.00;
  int checkpointCounter = 0;
  // Kept for legacy row-index checkpoint bands (visual only).
  static const int rowsPerCheckpoint = 10;
  static const double multiplierPerZone = 0.25;

  bool gameOver = false;
  double gameOverTimer = 0;

  // Camera Y in "row units": what row index corresponds to a certain screen y.
  // camY = row index at the bottom of the visible area.
  double camY = 0;

  void init(GameAssets a) {
    chicken = Chicken(col: cols ~/ 2, row: 0);
    // Pre-generate starting rows: several grass rows below and above.
    for (var i = -3; i <= 12; i++) {
      rows[i] = _generateRow(i, a, forceKind: i <= 2 ? RowKind.grass : null);
    }
    minRowGenerated = -3;
    maxRowGenerated = 12;
    camY = -2; // start with a bit of grass below chicken
  }

  RowData _generateRow(int idx, GameAssets a, {RowKind? forceKind}) {
    RowKind kind;
    if (forceKind != null) {
      kind = forceKind;
    } else {
      // Look at previous row to avoid too many hazards in a row.
      final prev = rows[idx - 1];
      final prevPrev = rows[idx - 2];
      final prevKind = prev?.kind;
      final prevPrevKind = prevPrev?.kind;

      // Prevent 3 hazards in a row.
      final twoHazardsBefore = _isHazard(prevKind) && _isHazard(prevPrevKind);

      if (twoHazardsBefore) {
        kind = _rng.nextBool() ? RowKind.grass : RowKind.pavement;
      } else if (prevKind == RowKind.road) {
        // Continue a road segment sometimes, but cap by chance.
        final segLen = _countBackKind(idx, RowKind.road);
        if (segLen >= 3) {
          kind = _rng.nextBool() ? RowKind.grass : RowKind.pavement;
        } else {
          final r = _rng.nextDouble();
          if (r < 0.5) {
            kind = RowKind.road;
          } else if (r < 0.75) {
            kind = RowKind.grass;
          } else {
            kind = RowKind.pavement;
          }
        }
      } else if (prevKind == RowKind.water) {
        final segLen = _countBackKind(idx, RowKind.water);
        if (segLen >= 3) {
          kind = RowKind.grass;
        } else {
          final r = _rng.nextDouble();
          if (r < 0.55) {
            kind = RowKind.water;
          } else if (r < 0.8) {
            kind = RowKind.grass;
          } else {
            kind = RowKind.pavement;
          }
        }
      } else {
        // From grass/pavement, chance to enter hazard.
        final r = _rng.nextDouble();
        if (r < 0.30) {
          kind = RowKind.road;
        } else if (r < 0.50) {
          kind = RowKind.water;
        } else if (r < 0.75) {
          kind = RowKind.grass;
        } else {
          kind = RowKind.pavement;
        }
      }
    }

    switch (kind) {
      case RowKind.grass:
        return _buildGrass(idx, a, false);
      case RowKind.pavement:
        return _buildPavement(idx, a, false);
      case RowKind.road:
        return _buildRoad(idx, a, false);
      case RowKind.water:
        return _buildWater(idx, a, false);
    }
  }

  bool _isHazard(RowKind? k) => k == RowKind.road || k == RowKind.water;

  int _countBackKind(int idx, RowKind kind) {
    var count = 0;
    var i = idx - 1;
    while (rows[i]?.kind == kind) {
      count++;
      i--;
    }
    return count;
  }

  RowData _buildGrass(int idx, GameAssets a, bool checkpoint) {
    final obstacles = <Obstacle>[];
    if (idx > 3) {
      final roll = _rng.nextDouble();
      if (roll < 0.20) {
        // One long fence blocking 3 cells; always leave at least one edge col
        // free for the chicken to pass.
        final centerCol = 1 + _rng.nextInt(cols - 2); // 1..cols-2
        obstacles.add(
          Obstacle(
            col: centerCol,
            image: a.fence,
            kind: ObstacleKind.fence,
            spanCells: 3,
            sourceCrop: ObstacleCrops.fence,
          ),
        );
      } else if (roll < 0.55) {
        final blocked = <int>{};
        final maxObs = 1 + _rng.nextInt(2);
        for (var i = 0; i < maxObs; i++) {
          final col = 1 + _rng.nextInt(cols - 2);
          if (blocked.contains(col)) continue;
          blocked.add(col);
          final small = _rng.nextBool();
          obstacles.add(
            Obstacle(
              col: col,
              image: small ? a.hay : a.rock,
              kind: small ? ObstacleKind.hay : ObstacleKind.rock,
              sourceCrop:
                  small ? ObstacleCrops.hay : ObstacleCrops.rock,
            ),
          );
        }
      }
      // Safety: make sure there is at least one passable column.
      final passable = List<bool>.generate(cols, (_) => true);
      for (final o in obstacles) {
        for (var c = 0; c < cols; c++) {
          if (o.blocks(c)) passable[c] = false;
        }
      }
      if (!passable.contains(true)) {
        obstacles.clear();
      }
    }
    return RowData(
      index: idx,
      kind: RowKind.grass,
      obstacles: obstacles,
      isCheckpoint: checkpoint,
    );
  }

  RowData _buildPavement(int idx, GameAssets a, bool checkpoint) {
    return RowData(
      index: idx,
      kind: RowKind.pavement,
      isCheckpoint: checkpoint,
    );
  }

  RowData _buildRoad(int idx, GameAssets a, bool checkpoint) {
    final direction = _rng.nextBool() ? 1 : -1;
    // Speed increases slightly with row index (difficulty).
    final baseSpeed = 2.5 + (idx / 30).clamp(0, 3);
    final speed = baseSpeed + _rng.nextDouble() * 1.2;
    final spawnInterval = 1.6 + _rng.nextDouble() * 1.8;
    final vehicleTypeRoll = _rng.nextInt(4);
    late VehicleSprite v;
    switch (vehicleTypeRoll) {
      case 0:
        // Red car: painted 256x158, aspect 1.62.
        v = VehicleSprite(
          image: a.carRed,
          widthCells: 1.50,
          defaultFacing: -1,
          canvasCells: 1.5,
          sourceCrop: const Rect.fromLTRB(128, 177, 384, 335),
        );
        break;
      case 1:
        // Blue truck: painted 256x132, aspect 1.94.
        v = VehicleSprite(
          image: a.carBlue,
          widthCells: 2.00,
          defaultFacing: 1,
          canvasCells: 2.0,
          sourceCrop: const Rect.fromLTRB(128, 190, 384, 322),
        );
        break;
      case 2:
        // Yellow bus: painted 256x116, aspect 2.21.
        v = VehicleSprite(
          image: a.bus,
          widthCells: 2.30,
          defaultFacing: -1,
          canvasCells: 2.3,
          sourceCrop: const Rect.fromLTRB(128, 198, 384, 314),
        );
        break;
      default:
        // Tractor: painted 256x200, aspect 1.28.
        v = VehicleSprite(
          image: a.tractor,
          widthCells: 1.30,
          defaultFacing: 1,
          canvasCells: 1.3,
          sourceCrop: const Rect.fromLTRB(128, 156, 384, 356),
        );
        break;
    }
    final row = RowData(
      index: idx,
      kind: RowKind.road,
      direction: direction,
      speed: speed,
      vehicle: v,
      spawnInterval: spawnInterval,
      isCheckpoint: checkpoint,
    );
    // Pre-spawn a couple of cars for variety.
    row.spawnTimer = _rng.nextDouble() * spawnInterval;
    // Optionally place one on-screen already.
    if (_rng.nextBool()) {
      final startX = _rng.nextDouble() * cols.toDouble();
      row.movers.add(
        MovingEntity(
          xCells: startX,
          widthCells: v.widthCells,
          speed: direction * speed,
        ),
      );
    }
    return row;
  }

  RowData _buildWater(int idx, GameAssets a, bool checkpoint) {
    final direction = _rng.nextBool() ? 1 : -1;
    final baseSpeed = 1.4 + (idx / 60).clamp(0, 1.5);
    final speed = baseSpeed + _rng.nextDouble() * 0.6;
    final spawnInterval = 1.3 + _rng.nextDouble() * 1.4;
    final row = RowData(
      index: idx,
      kind: RowKind.water,
      direction: direction,
      speed: speed,
      // Precise painted body of the (lower) log, extracted via PIL.getbbox
      // (119, 351)..(374, 420). Aspect ~ 3.70.
      vehicle: VehicleSprite(
        image: a.log,
        widthCells: 2.50,
        defaultFacing: 1,
        canvasCells: 3.0,
        sourceCrop: const Rect.fromLTRB(119, 351, 374, 420),
      ),
      spawnInterval: spawnInterval,
      isCheckpoint: checkpoint,
    );
    row.spawnTimer = _rng.nextDouble() * spawnInterval * 0.5;
    // Pre-place logs across the row so player has landing pads.
    var x = -row.vehicle!.widthCells + _rng.nextDouble() * 1.5;
    while (x < cols + row.vehicle!.widthCells) {
      row.movers.add(
        MovingEntity(
          xCells: x,
          widthCells: row.vehicle!.widthCells,
          speed: direction * speed,
        ),
      );
      x += row.vehicle!.widthCells + 1.5 + _rng.nextDouble() * 1.5;
    }
    return row;
  }

  void extendIfNeeded(GameAssets a) {
    while (maxRowGenerated < chicken.row + 20) {
      maxRowGenerated++;
      rows[maxRowGenerated] = _generateRow(maxRowGenerated, a);
    }
    // Cleanup old rows below (memory).
    while (minRowGenerated < chicken.row - 15) {
      rows.remove(minRowGenerated);
      minRowGenerated++;
    }
  }

  void update(double dt, GameAssets a) {
    if (gameOver) {
      gameOverTimer += dt;
      return;
    }

    extendIfNeeded(a);

    // Update bump animation (blocked move feedback).
    if (chicken.bumping) {
      chicken.bumpProgress += dt / 0.18;
      if (chicken.bumpProgress >= 1.0) {
        chicken.bumpProgress = 0;
      }
    }

    // Update chicken hop animation.
    if (chicken.hopping) {
      chicken.hopProgress += dt / 0.14; // ~140ms per hop
      if (chicken.hopProgress >= 1.0) {
        chicken.hopProgress = 1.0;
        chicken.hopping = false;
        final prevRow = chicken.row;
        chicken.col = chicken.hopToCol;
        chicken.row = chicken.hopToRow;
        chicken.xPxOffset = chicken.hopToOffsetPx;
        if (chicken.row > maxRowReached) {
          maxRowReached = chicken.row;
          _maybeAwardHazardMultiplier(prevRow, chicken.row);
        }
        _onLandOnRow();
      }
    }

    // Update movers on all rows.
    rows.forEach((idx, row) {
      if (row.kind == RowKind.road || row.kind == RowKind.water) {
        row.spawnTimer -= dt;
        if (row.spawnTimer <= 0 && row.kind == RowKind.road) {
          row.spawnTimer = row.spawnInterval;
          _spawnCar(row);
        }
        for (final m in row.movers) {
          m.xCells += m.speed * dt;
        }
        // Remove far off-screen movers.
        row.movers.removeWhere((m) {
          if (m.speed > 0) {
            return m.xCells > cols + 4;
          } else {
            return m.xCells + m.widthCells < -4;
          }
        });
        // Keep water rows populated with logs.
        if (row.kind == RowKind.water) {
          _keepWaterPopulated(row);
        }
      }
    });

    // If riding a log, chicken's screen X follows log.
    if (!chicken.hopping && chicken.ridingLog != null) {
      final log = chicken.ridingLog!;
      // xPxOffset is the offset from chicken's nominal col center due to log drift.
      chicken.xPxOffset += log.speed * dt; // still in cell units
      // Check if drifted off-screen.
      final effectiveCol = chicken.col + chicken.xPxOffset;
      if (effectiveCol < -0.5 || effectiveCol > cols - 0.5) {
        _die();
        return;
      }
    }

    // Collision checks (only when not hopping to avoid mid-air kills).
    if (!chicken.hopping) {
      final row = rows[chicken.row];
      if (row != null) {
        _checkRowCollision(row);
      }
    }
  }

  void _spawnCar(RowData row) {
    final v = row.vehicle!;
    final speed = row.direction * row.speed;
    const gapCells = 1.6;
    // Ensure spacing from the last spawned (trailing) car.
    for (final m in row.movers) {
      if (row.direction > 0) {
        // trailing = smallest xCells; must have advanced past spawn point + gap.
        if (m.xCells < -0.2 + gapCells) return;
      } else {
        // trailing = largest xCells + widthCells; must have advanced past cols - gap.
        if (m.xCells + m.widthCells > cols + 0.2 - gapCells) return;
      }
    }

    final startX = row.direction > 0
        ? -v.widthCells - 0.2
        : cols.toDouble() + 0.2;
    row.movers.add(
      MovingEntity(
        xCells: startX,
        widthCells: v.widthCells,
        speed: speed,
      ),
    );
  }

  void _keepWaterPopulated(RowData row) {
    final v = row.vehicle!;
    // If there's no log heading in soon, add one at the spawn edge.
    final incoming = row.movers.any((m) {
      if (row.direction > 0) {
        return m.xCells < 2;
      } else {
        return m.xCells + m.widthCells > cols - 2;
      }
    });
    if (!incoming) {
      final startX = row.direction > 0
          ? -v.widthCells - _rng.nextDouble()
          : cols.toDouble() + _rng.nextDouble();
      row.movers.add(
        MovingEntity(
          xCells: startX,
          widthCells: v.widthCells,
          speed: row.direction * row.speed,
        ),
      );
    }
  }

  void _onLandOnRow() {
    final row = rows[chicken.row];
    if (row == null) return;

    // Reset log riding by default.
    chicken.ridingLog = null;

    if (row.kind == RowKind.water) {
      // The chicken keeps whatever offset it landed with; if that visual
      // position lies inside a log (with a small tolerance), it rides the
      // log. Otherwise, splash.
      final centerCol = chicken.col + chicken.xPxOffset + 0.5;
      MovingEntity? on;
      for (final m in row.movers) {
        if (centerCol >= m.leftCell + 0.2 && centerCol <= m.rightCell - 0.2) {
          on = m;
          break;
        }
      }
      if (on == null) {
        _die();
      } else {
        chicken.ridingLog = on;
      }
    } else if (row.kind == RowKind.grass) {
      // Landed on an obstacle?
      for (final o in row.obstacles) {
        if (o.blocks(chicken.col)) {
          _die();
          return;
        }
      }
    }
  }

  void _checkRowCollision(RowData row) {
    if (row.kind != RowKind.road) return;
    final chickenLeft = chicken.col + chicken.xPxOffset + 0.15;
    final chickenRight = chicken.col + chicken.xPxOffset + 0.85;
    for (final m in row.movers) {
      if (m.rightCell > chickenLeft && m.leftCell < chickenRight) {
        _die();
        return;
      }
    }
  }

  // Award a multiplier bump once whenever the chicken advances forward off a
  // hazard (road/water) onto a safe row for the first time.
  void _maybeAwardHazardMultiplier(int prevRow, int newRow) {
    if (newRow <= prevRow) return;
    final prevData = rows[prevRow];
    final newData = rows[newRow];
    if (prevData == null || newData == null) return;
    final wasHazard = _isHazard(prevData.kind);
    final nowSafe = !_isHazard(newData.kind);
    if (wasHazard && nowSafe) {
      multiplier += multiplierPerZone;
      checkpointCounter++;
    }
  }

  void _die() {
    if (!chicken.alive) return;
    chicken.alive = false;
    gameOver = true;
  }

  void forceKill() => _die();

  bool _canMoveTo(int col, int rowIdx) {
    if (col < 0 || col >= cols) return false;
    if (rowIdx < 0) return false;
    final r = rows[rowIdx];
    if (r == null) return true;
    if (r.kind == RowKind.grass) {
      for (final o in r.obstacles) {
        if (o.blocks(col)) return false;
      }
    }
    return true;
  }

  void tryMove(int dCol, int dRow, GameAssets a) {
    if (gameOver || chicken.hopping) return;

    // Hop by exactly one cell in the direction the player swiped, measured
    // from the chicken's VISUAL position (chicken.col + xPxOffset). This
    // guarantees the sprite always travels the same distance regardless of
    // whether it was drifting on a log, so there is no teleport when
    // entering or leaving a log.
    final visualCol = chicken.col + chicken.xPxOffset;
    final targetVisualCol = visualCol + dCol.toDouble();
    final newRow = chicken.row + dRow;
    final gridTargetCol = targetVisualCol.round();

    if (!_canMoveTo(gridTargetCol, newRow)) {
      chicken.bumpDx = dCol.toDouble();
      chicken.bumpDy = dRow.toDouble();
      chicken.bumpProgress = 0.001;
      return;
    }

    chicken.hopFromCol = chicken.col;
    chicken.hopFromRow = chicken.row;
    chicken.hopFromOffsetPx = chicken.xPxOffset;
    chicken.hopToCol = gridTargetCol;
    chicken.hopToRow = newRow;
    chicken.hopToOffsetPx = targetVisualCol - gridTargetCol;
    chicken.hopping = true;
    chicken.hopProgress = 0;
  }

  // Chicken's current fractional position for rendering.
  double get chickenColD {
    if (!chicken.hopping) {
      return chicken.col + chicken.xPxOffset;
    }
    final t = _easeOutQuad(chicken.hopProgress);
    final from = chicken.hopFromCol + chicken.hopFromOffsetPx;
    final to = chicken.hopToCol + chicken.hopToOffsetPx;
    return from + (to - from) * t;
  }

  double get chickenRowD {
    if (!chicken.hopping) return chicken.row.toDouble();
    final t = _easeOutQuad(chicken.hopProgress);
    return chicken.hopFromRow + (chicken.hopToRow - chicken.hopFromRow) * t;
  }

  double _easeOutQuad(double t) => 1 - (1 - t) * (1 - t);

  int computeFinalScore() => (maxRowReached * multiplier).round();
}
