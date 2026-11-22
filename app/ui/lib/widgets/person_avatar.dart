import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// A person's round avatar: their initials on a color picked from their id,
/// so everyone sees the same color for the same friend. [online] adds a
/// green dot.
///
/// [photo] is the person's picture path from the Hub; the initials show
/// while it loads, or when there's none.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({super.key, required this.id, required this.name, this.size = 36, this.online, this.photo});

  final String id;
  final String name;
  final double size;
  final bool? online;
  final String? photo;

  static const _colors = [
    Color(0xFF7C9CFF),
    Color(0xFF26A69A),
    Color(0xFFFF7A59),
    Color(0xFFFFB300),
    Color(0xFFE91E63),
    Color(0xFF9C27B0),
    Color(0xFF8BC34A),
    Color(0xFF29B6F6),
  ];

  static String initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    final first = parts.first.characters.first;
    final second = parts.length > 1 ? parts.last.characters.first : '';
    return (first + second).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final color = _colors[id.codeUnits.fold<int>(0, (a, c) => (a * 31 + c) & 0x7fffffff) % _colors.length];
    final session = context.read<HubSession>();
    final url = session.photoUrl(photo);
    final face = CircleAvatar(
      radius: size / 2,
      backgroundColor: color,
      foregroundImage: url == null ? null : NetworkImage(url.toString(), headers: session.photoHeaders),
      onForegroundImageError: url == null ? null : (_, _) {},
      child: Text(
        initials(name),
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: size * 0.38),
      ),
    );
    if (online == null) return face;
    final surface = Theme.of(context).colorScheme.surfaceContainerHigh;
    final dot = size * 0.3;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        children: [
          face,
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: dot,
              height: dot,
              decoration: BoxDecoration(
                color: online! ? const Color(0xFF3ECF8E) : Colors.grey,
                shape: BoxShape.circle,
                border: Border.all(color: surface, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
