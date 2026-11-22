import 'dart:convert';
import 'dart:io';

import 'package:couchmates_core/couchmates_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

String sample(String name) => File('../../core/contract/$name').readAsStringSync();

void main() {
  test('parseHubAddress', () {
    expect(parseHubAddress('hub.example.com/')?.toString(), 'https://hub.example.com');
    expect(parseHubAddress('http://127.0.0.1:8787')?.toString(), 'http://127.0.0.1:8787');
    expect(parseHubAddress('ftp://x'), isNull);
    expect(parseHubAddress('  '), isNull);
  });

  test('login keeps the token and sends it afterwards', () async {
    final seen = <http.Request>[];
    final client = HubClient(
      baseUrl: Uri.parse('https://hub.example.com'),
      httpClient: MockClient((request) async {
        seen.add(request);
        return switch (request.url.path) {
          HubPaths.login => http.Response(sample('login_response.json'), 200),
          HubPaths.config => http.Response(sample('config_response.json'), 200),
          _ => http.Response('{"error":"Not found"}', 404),
        };
      }),
    );
    final login = await client.login(const LoginRequest(username: 'alice', password: 'pw', deviceName: 'PC'));
    expect(login.user.username, 'alice');
    expect(jsonDecode(seen.first.body), {'username': 'alice', 'password': 'pw', 'device_name': 'PC'});
    expect(seen.first.headers['authorization'], isNull);

    final config = await client.config();
    expect(seen.last.headers['authorization'], 'Bearer ${login.token}');
    expect(config.addon?.manifestUrl, endsWith('/manifest.json'));
  });

  test('errors carry the Hub message and status', () async {
    final client = HubClient(
      baseUrl: Uri.parse('https://hub.example.com'),
      token: 'old',
      httpClient: MockClient((_) async => http.Response(sample('error_response.json'), 401)),
    );
    await expectLater(
      client.config(),
      throwsA(
        isA<HubException>()
            .having((e) => e.message, 'message', 'Wrong username or password.')
            .having((e) => e.signedOut, 'signedOut', true),
      ),
    );
  });

  test('unreachable Hub', () async {
    final client = HubClient(
      baseUrl: Uri.parse('https://hub.example.com'),
      httpClient: MockClient((_) async => throw const SocketException('down')),
    );
    await expectLater(client.config(), throwsA(isA<HubException>().having((e) => e.status, 'status', isNull)));
  });

  test('logout clears the token even if the Hub is down', () async {
    final client = HubClient(
      baseUrl: Uri.parse('https://hub.example.com'),
      token: 't',
      httpClient: MockClient((_) async => throw const SocketException('down')),
    );
    await expectLater(client.logout(), throwsA(isA<HubException>()));
    expect(client.token, isNull);
  });

  test('update check sends platform and version as a query', () async {
    late Uri seen;
    final client = HubClient(
      baseUrl: Uri.parse('https://hub.example.com'),
      token: 't',
      httpClient: MockClient((request) async {
        seen = request.url;
        return http.Response(sample('update_info.json'), 200);
      }),
    );
    final info = await client.update(platform: 'windows', version: '0.1.0');
    expect(seen.path, '/api/app/update');
    expect(seen.queryParameters, {'platform': 'windows', 'version': '0.1.0'});
    expect(info.newer, isTrue);
    expect(info.latestVersion, '0.2.0');
  });
}
