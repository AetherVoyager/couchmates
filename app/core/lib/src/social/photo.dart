import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Side of the square the Hub keeps: sharp at the largest avatar the app
/// draws (80 px) on a 3x screen, and about 30 KB as a JPEG.
const photoSize = 256;

/// [bytes] (any JPEG, PNG, WebP, GIF or BMP) turned the right way up,
/// cropped to a centered square and shrunk to [size], as a JPEG. Null when
/// it isn't a picture.
Uint8List? preparePhoto(Uint8List bytes, {int size = photoSize}) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final upright = img.bakeOrientation(decoded);
  final side = math.min(upright.width, upright.height);
  final square = img.copyCrop(
    upright,
    x: (upright.width - side) ~/ 2,
    y: (upright.height - side) ~/ 2,
    width: side,
    height: side,
  );
  final small = side > size
      ? img.copyResize(square, width: size, height: size, interpolation: img.Interpolation.average)
      : square;
  return img.encodeJpg(small, quality: 85);
}

/// [preparePhoto] off the UI thread.
Future<Uint8List?> preparePhotoInBackground(Uint8List bytes) => Isolate.run(() => preparePhoto(bytes));
