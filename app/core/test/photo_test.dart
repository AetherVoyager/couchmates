import 'dart:convert';
import 'dart:typed_data';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

void main() {
  test('pictures become a centered 256 px square JPEG', () {
    // Wide picture: red left third, green middle, blue right third.
    final wide = img.Image(width: 900, height: 300);
    for (var x = 0; x < 900; x++) {
      for (var y = 0; y < 300; y++) {
        wide.setPixelRgb(x, y, x < 300 ? 255 : 0, x >= 300 && x < 600 ? 255 : 0, x >= 600 ? 255 : 0);
      }
    }
    final out = preparePhoto(img.encodePng(wide))!;
    expect(out.sublist(0, 3), [0xFF, 0xD8, 0xFF]);
    final back = img.decodeJpg(out)!;
    expect((back.width, back.height), (256, 256));
    final centre = back.getPixel(128, 128);
    expect(centre.g, greaterThan(200), reason: 'the middle third is kept');
    expect(centre.r, lessThan(60));
    expect(out.length, lessThan(60 * 1024));
  });

  test('small pictures are not blown up, and non-pictures are refused', () {
    final small = preparePhoto(img.encodePng(img.Image(width: 64, height: 80)))!;
    expect(img.decodeJpg(small)!.width, 64);
    expect(preparePhoto(Uint8List.fromList(utf8.encode('<svg></svg>'))), isNull);
  });

  test('upload sends base64 and photo addresses carry the token', () async {
    late http.Request sent;
    final hub = HubClient(
      baseUrl: Uri.parse('https://hub.example.com/base'),
      token: 'tok',
      httpClient: MockClient((r) async {
        sent = r;
        return http.Response(
          '{"user":{"id":"a","name":"A","username":"a","photo":"/api/app/photos/a?v=2"},"devices":[]}',
          200,
        );
      }),
    );
    final profile = await hub.uploadPhoto(Uint8List.fromList([0xFF, 0xD8, 0xFF, 1]));
    expect(jsonDecode(sent.body), {'image': '/9j/AQ=='});
    expect(hub.photoUrl(profile.user.photo!).toString(), 'https://hub.example.com/base/api/app/photos/a?v=2');
    expect(hub.authHeaders, {'authorization': 'Bearer tok'});
  });
}
