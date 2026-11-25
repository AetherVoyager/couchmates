import 'package:flutter/material.dart';

/// The blue tick next to a chat admin's name.
class VerifiedBadge extends StatelessWidget {
  const VerifiedBadge({super.key, this.size = 14});

  final double size;

  /// The tick's colour: the familiar "verified" blue, in both themes.
  static const color = Color(0xFF1D9BF0);

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Chat admin',
    child: Icon(Icons.verified_rounded, size: size, color: color, semanticLabel: 'Verified chat admin'),
  );
}

/// [name] in [style], with the [VerifiedBadge] after it for a chat [admin].
class VerifiedName extends StatelessWidget {
  const VerifiedName(this.name, {super.key, required this.admin, this.style});

  final String name;
  final bool admin;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final text = Text(name, style: style, maxLines: 1, overflow: TextOverflow.ellipsis);
    if (!admin) return text;
    final size = ((style ?? DefaultTextStyle.of(context).style).fontSize ?? 14) + 1;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: text),
        const SizedBox(width: 3),
        VerifiedBadge(size: size),
      ],
    );
  }
}
