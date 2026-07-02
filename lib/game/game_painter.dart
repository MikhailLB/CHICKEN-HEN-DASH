import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'game_assets.dart';
import 'game_state.dart';

class GamePainter extends CustomPainter {
  GamePainter({
    required this.state,
    required this.assets,
    required this.cellSize,
    required this.camY,
  });

  final GameState state;
  final GameAssets assets;
  final double cellSize;
  final double camY;

  // Tight bounding boxes for each pose inside the 512x512 sprite sheet. The
  // four poses are arranged in a 2x2 grid but each chicken is drawn in the
  // *inner* corner of its quadrant (i.e. towards the sheet's centre), so we
  // crop precisely instead of using the 256x256 sub-quadrant rects.
  static const Rect _chickenSrcIdle = Rect.fromLTRB(140, 120, 244, 240);
  static const Rect _chickenSrcWings = Rect.fromLTRB(130, 250, 260, 372);
  static const Rect _chickenSrcDead = Rect.fromLTRB(265, 265, 380, 390);

  @override
  void paint(Canvas canvas, Size size) {
    final rowHeight = cellSize;
    final boardWidth = state.cols * cellSize;
    final xOffset = (size.width - boardWidth) / 2;

    canvas.save();
    canvas.clipRect(Offset.zero & size);

    // Determine visible rows.
    final bottomRow = camY.floor() - 1;
    final topRow = camY.floor() + (size.height / rowHeight).ceil() + 2;

    // Draw rows (bottom to top for correct z-order of movers above tiles).
    for (var r = bottomRow; r <= topRow; r++) {
      final row = state.rows[r];
      if (row == null) continue;
      final y = size.height - (r - camY) * rowHeight - rowHeight;
      final rect = Rect.fromLTWH(xOffset, y, boardWidth, rowHeight);
      _drawRowTile(canvas, row, rect);
    }
    // Second pass: obstacles and movers so they render above their row tile
    // but below chicken.
    for (var r = bottomRow; r <= topRow; r++) {
      final row = state.rows[r];
      if (row == null) continue;
      final y = size.height - (r - camY) * rowHeight - rowHeight;
      _drawRowContent(canvas, row, xOffset, y, rowHeight);
    }

    // Draw chicken on top of its row (and any log it stands on).
    _drawChicken(canvas, size, xOffset, rowHeight);

    canvas.restore();

    _drawHud(canvas, size);

    if (state.gameOver) {
      _drawGameOver(canvas, size);
    }
  }

  void _drawRowTile(Canvas canvas, RowData row, Rect rect) {
    switch (row.kind) {
      case RowKind.grass:
        _tileHoriz(canvas, assets.grass, rect);
        break;
      case RowKind.pavement:
        _tileHoriz(canvas, assets.pavement, rect);
        break;
      case RowKind.water:
        _tileHoriz(canvas, assets.water, rect);
        break;
      case RowKind.road:
        // Road source has a vertical dashed line; rotate 90° so the dashed
        // line runs horizontally along the row (same as car direction).
        _tileRoad(canvas, assets.road, rect);
        break;
    }
  }

  void _tileHoriz(Canvas canvas, ui.Image tile, Rect rect) {
    // One tile = one row height square; tile across the row width.
    final tileSize = rect.height;
    final srcRect = Rect.fromLTWH(
      0,
      0,
      tile.width.toDouble(),
      tile.height.toDouble(),
    );
    final paint = Paint()..filterQuality = FilterQuality.medium;
    canvas.save();
    canvas.clipRect(rect);
    final count = (rect.width / tileSize).ceil() + 1;
    for (var i = 0; i < count; i++) {
      final dst = Rect.fromLTWH(
        rect.left + i * tileSize,
        rect.top,
        tileSize,
        tileSize,
      );
      canvas.drawImageRect(tile, srcRect, dst, paint);
    }
    canvas.restore();
  }

  void _tileRoad(Canvas canvas, ui.Image tile, Rect rect) {
    // Rotate the road tile 90° clockwise so the vertical dashed line in the
    // source becomes horizontal in the destination.
    final tileSize = rect.height;
    final srcRect = Rect.fromLTWH(
      0,
      0,
      tile.width.toDouble(),
      tile.height.toDouble(),
    );
    final paint = Paint()..filterQuality = FilterQuality.medium;
    canvas.save();
    canvas.clipRect(rect);
    final count = (rect.width / tileSize).ceil() + 1;
    for (var i = 0; i < count; i++) {
      final dstCenter = Offset(
        rect.left + i * tileSize + tileSize / 2,
        rect.top + tileSize / 2,
      );
      canvas.save();
      canvas.translate(dstCenter.dx, dstCenter.dy);
      canvas.rotate(math.pi / 2);
      final dst = Rect.fromCenter(
        center: Offset.zero,
        width: tileSize,
        height: tileSize,
      );
      canvas.drawImageRect(tile, srcRect, dst, paint);
      canvas.restore();
    }
    canvas.restore();
  }

  void _drawRowContent(
    Canvas canvas,
    RowData row,
    double xOffset,
    double y,
    double rowHeight,
  ) {
    if (row.kind == RowKind.grass) {
      for (final o in row.obstacles) {
        final cx = xOffset + o.col * cellSize + cellSize / 2;
        final cy = y + rowHeight / 2;
        final crop = o.sourceCrop;
        double w;
        double h;
        switch (o.kind) {
          case ObstacleKind.fence:
            // Draw the fence at exactly `spanCells` cells wide so that the
            // visible planks line up with the blocked cells. Height follows
            // the natural aspect of the painted body — no stretching.
            w = cellSize * o.spanCells.toDouble();
            if (crop != null) {
              h = w * (crop.height / crop.width);
            } else {
              h = w * 0.30;
            }
            break;
          case ObstacleKind.hay:
            w = cellSize * 0.95;
            if (crop != null) {
              h = w * (crop.height / crop.width);
            } else {
              h = w;
            }
            break;
          case ObstacleKind.rock:
            w = cellSize * 0.90;
            if (crop != null) {
              h = w * (crop.height / crop.width);
            } else {
              h = w;
            }
            break;
        }
        final dst = Rect.fromCenter(
          center: Offset(cx, cy),
          width: w,
          height: h,
        );
        _drawSprite(canvas, o.image, dst, src: crop);
      }
    } else if (row.kind == RowKind.road || row.kind == RowKind.water) {
      final v = row.vehicle;
      if (v == null) return;
      final crop = v.sourceCrop;
      for (final m in row.movers) {
        final logicalCenterX =
            xOffset + (m.xCells + m.widthCells / 2) * cellSize;
        final logicalCenterY = y + rowHeight / 2;
        late Rect dst;
        if (crop != null) {
          // Size sprite so its width equals the collision width and its
          // height follows the crop aspect (log stays inside its row).
          final dstW = m.widthCells * cellSize;
          final dstH = dstW * (crop.height / crop.width);
          dst = Rect.fromCenter(
            center: Offset(logicalCenterX, logicalCenterY),
            width: dstW,
            height: dstH,
          );
        } else {
          final canvasSize = v.canvasCells * cellSize;
          dst = Rect.fromCenter(
            center: Offset(logicalCenterX, logicalCenterY),
            width: canvasSize,
            height: canvasSize,
          );
        }
        final movingDir = m.speed >= 0 ? 1 : -1;
        final flip = movingDir != v.defaultFacing;
        _drawSprite(canvas, v.image, dst, flip: flip, src: crop);
      }
    }
  }

  void _drawSprite(
    Canvas canvas,
    ui.Image image,
    Rect dst, {
    bool flip = false,
    Rect? src,
  }) {
    final s = src ??
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    canvas.save();
    if (flip) {
      canvas.translate(dst.center.dx, dst.center.dy);
      canvas.scale(-1, 1);
      canvas.translate(-dst.center.dx, -dst.center.dy);
    }
    canvas.drawImageRect(
      image,
      s,
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }

  void _drawChicken(Canvas canvas, Size size, double xOffset, double rowHeight) {
    // Choose the pose crop first so we can size the dst rect to keep the
    // painted chicken's aspect ratio and centre it precisely on the cell.
    Rect src;
    if (!state.chicken.alive) {
      src = _chickenSrcDead;
    } else if (state.chicken.hopping) {
      src = _chickenSrcWings;
    } else {
      src = _chickenSrcIdle;
    }

    // Chicken sized so its painted body fits comfortably inside a log
    // (which is ~0.68 cell tall).
    final chickenH = cellSize * 0.72;
    final chickenW = chickenH * (src.width / src.height);

    final colD = state.chickenColD;
    final rowD = state.chickenRowD;
    final cellCenterX = xOffset + colD * cellSize + cellSize / 2;
    final cellCenterY =
        size.height - (rowD - camY) * rowHeight - rowHeight + rowHeight / 2;
    var x = cellCenterX - chickenW / 2;
    var y = cellCenterY - chickenH / 2;

    // Small hop lift.
    if (state.chicken.hopping) {
      final t = state.chicken.hopProgress;
      final lift = -8 * (t * (1 - t)) * 4; // parabola peaking at t=0.5
      y += lift * (cellSize / 40);
    }

    // Bump: nudge the chicken toward the blocked direction and back.
    if (state.chicken.bumping) {
      final t = state.chicken.bumpProgress;
      final wave = math.sin(t * math.pi);
      final nudge = wave * 0.28 * cellSize;
      x += state.chicken.bumpDx * nudge;
      y += -state.chicken.bumpDy * nudge;
    }

    final dst = Rect.fromLTWH(x, y, chickenW, chickenH);
    // Soft shadow underneath.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(dst.center.dx, dst.bottom - chickenH * 0.06),
        width: chickenW * 0.72,
        height: chickenH * 0.20,
      ),
      Paint()..color = const Color(0x66000000),
    );
    _drawSprite(canvas, assets.chickens, dst, src: src);
  }

  void _drawHud(Canvas canvas, Size size) {
    final tp = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: '${state.maxRowReached}',
        style: const TextStyle(
          fontSize: 40,
          fontWeight: FontWeight.w900,
          color: Colors.white,
          shadows: [
            Shadow(color: Color(0xFF3B2100), offset: Offset(0, 3), blurRadius: 0),
            Shadow(color: Color(0x99000000), offset: Offset(0, 4), blurRadius: 8),
          ],
        ),
      ),
    )..layout();
    tp.paint(canvas, Offset((size.width - tp.width) / 2, 40));

    // Multiplier badge (top-right).
    final multStr = 'x${state.multiplier.toStringAsFixed(2)}';
    final mtp = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: multStr,
        style: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w900,
          color: Colors.white,
          shadows: [
            Shadow(color: Color(0xFF7A3C00), offset: Offset(0, 2), blurRadius: 0),
          ],
        ),
      ),
    )..layout();
    final padH = 12.0;
    final padV = 8.0;
    final badgeRect = Rect.fromLTWH(
      size.width - mtp.width - padH * 2 - 16,
      40,
      mtp.width + padH * 2,
      mtp.height + padV * 2,
    );
    final badgePaint = Paint()..color = const Color(0xCC5B3A00);
    canvas.drawRRect(
      RRect.fromRectAndRadius(badgeRect, const Radius.circular(14)),
      badgePaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(badgeRect, const Radius.circular(14)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white,
    );
    mtp.paint(
      canvas,
      Offset(badgeRect.left + padH, badgeRect.top + padV),
    );
  }

  void _drawGameOver(Canvas canvas, Size size) {
    final overlay = Paint()..color = const Color(0x88000000);
    canvas.drawRect(Offset.zero & size, overlay);
  }

  @override
  bool shouldRepaint(covariant GamePainter old) => true;
}
