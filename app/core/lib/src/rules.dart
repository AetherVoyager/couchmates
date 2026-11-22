/// The rules in `core/src/rules.rs`, so the app can check input before
/// asking the Hub. `core/contract/rules.json` holds the cases both sides test.
library;

const minPasswordLength = 8;
const maxPasswordBytes = 256;

final _usernameChars = RegExp(r'^[a-z0-9._-]+$');

/// [input] as a username (lower case `a-z 0-9 . _ -`, 3–32 long), or null.
String? normalizeUsername(String input) {
  final name = input.trim().toLowerCase();
  final ok = name.length >= 3 && name.length <= 32 && _usernameChars.hasMatch(name);
  return ok ? name : null;
}

/// What's wrong with [password] as a new password, or null.
String? passwordProblem(String password) {
  if (password.runes.length < minPasswordLength) {
    return 'Passwords need at least $minPasswordLength characters.';
  }
  if (_utf8Length(password) > maxPasswordBytes) return 'That password is too long.';
  return null;
}

/// The voice room for a watch party room code: letters and digits only,
/// upper-cased, 4–16 long.
String? roomForWatchCode(String code) {
  final cleaned = code.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
  return cleaned.length >= 4 && cleaned.length <= 16 ? 'couchmates-$cleaned' : null;
}

int _utf8Length(String s) {
  var n = 0;
  for (final r in s.runes) {
    n += r < 0x80 ? 1 : (r < 0x800 ? 2 : (r < 0x10000 ? 3 : 4));
  }
  return n;
}
