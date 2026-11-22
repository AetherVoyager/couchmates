import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../settings/app_settings.dart';
import '../stremio/models.dart';

/// "My list": titles the user saved for later, on this device, newest first.
class Watchlist extends ChangeNotifier {
  Watchlist(this._store);

  static const _key = 'watchlist.entries';

  final SettingsStore _store;
  final List<StremioMeta> _items = [];

  List<StremioMeta> get items => List.unmodifiable(_items);

  bool contains(String id) => _items.any((m) => m.id == id);

  Future<void> load() async {
    final raw = (await _store.load())[_key];
    _items.clear();
    if (raw is String) {
      try {
        for (final e in jsonDecode(raw) as List) {
          if (e is Map<String, dynamic>) _items.add(StremioMeta.fromJson(e));
        }
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> toggle(StremioMeta meta) async {
    if (contains(meta.id)) {
      _items.removeWhere((m) => m.id == meta.id);
    } else {
      _items.insert(0, meta);
    }
    await _store.write(
      _key,
      jsonEncode([
        for (final m in _items)
          {
            'id': m.id,
            'type': m.type,
            'name': m.name,
            'poster': ?m.poster,
            'background': ?m.background,
            'year': ?m.year,
          },
      ]),
    );
    notifyListeners();
  }
}
