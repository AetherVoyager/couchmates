import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';

/// What a toast is about, which sets its icon and colour.
enum ToastTone { info, success, error }

/// One notice in the top-right corner.
class Toast {
  Toast._(this.id, this.text, this.tone, this.action, this.onAction, this.duration, this.tag);

  final int id;
  final String text;
  final ToastTone tone;

  /// A button on the toast, such as "Watch"; pressing it also closes the toast.
  final String? action;
  final VoidCallback? onAction;

  /// How long it stays before fading out. Hovering it holds it.
  final Duration duration;

  /// A new toast with the same tag replaces this one (such as the player's "Resumed at").
  final String? tag;
}

/// The app's notices: small boxes in the top-right corner over every screen, shown by [ToastHost]. Each fades out
/// after [Toasts.defaultDuration] or closes with its close button.
class Toasts extends ChangeNotifier {
  static const defaultDuration = Duration(seconds: 15);

  /// At most this many show at once; the oldest goes first.
  static const maxShown = 4;

  final List<Toast> _shown = [];
  int _next = 0;

  List<Toast> get shown => List.unmodifiable(_shown);

  /// Shows [text]. With [tag], replaces the toast already shown with that tag.
  Toast show(
    String text, {
    ToastTone tone = ToastTone.info,
    String? action,
    VoidCallback? onAction,
    Duration duration = defaultDuration,
    String? tag,
  }) {
    if (tag != null) _shown.removeWhere((t) => t.tag == tag);
    final toast = Toast._(_next++, text, tone, action, onAction, duration, tag);
    _shown.add(toast);
    while (_shown.length > maxShown) {
      _shown.removeAt(0);
    }
    notifyListeners();
    return toast;
  }

  Toast success(String text, {String? tag}) => show(text, tone: ToastTone.success, tag: tag);

  Toast error(String text, {String? tag}) => show(text, tone: ToastTone.error, tag: tag);

  void dismiss(Toast toast) {
    if (_shown.remove(toast)) notifyListeners();
  }

  void clear() {
    if (_shown.isEmpty) return;
    _shown.clear();
    notifyListeners();
  }
}

/// The app's one [Toasts].
final toasts = Toasts();

/// Floats [Toasts] in the top-right corner over [child] (the navigator), newest at the bottom of the stack.
class ToastHost extends StatelessWidget {
  const ToastHost({super.key, required this.child, this.controller});

  final Widget child;

  /// The toasts to show; the app's [toasts] unless a test passes its own.
  final Toasts? controller;

  @override
  Widget build(BuildContext context) {
    final source = controller ?? toasts;
    final width = (MediaQuery.sizeOf(context).width - 32).clamp(0.0, 380.0);
    return Stack(
      children: [
        child,
        Positioned(
          top: 16 + MediaQuery.paddingOf(context).top,
          right: 16,
          width: width,
          child: ListenableBuilder(
            listenable: source,
            builder: (context, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final t in source.shown)
                  _ToastCard(key: ValueKey(t.id), toast: t, onGone: () => source.dismiss(t)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ToastCard extends StatefulWidget {
  const _ToastCard({super.key, required this.toast, required this.onGone});

  final Toast toast;
  final VoidCallback onGone;

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard> with TickerProviderStateMixin {
  static const _fade = Duration(milliseconds: 260);

  late final AnimationController _show = AnimationController(vsync: this, duration: _fade)..forward();
  late final AnimationController _life = AnimationController(vsync: this, duration: widget.toast.duration);
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _life
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) _close();
      })
      ..forward();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _life.stop();
    await _show.reverse();
    if (mounted) widget.onGone();
  }

  void _hold(bool hovering) {
    if (_closing) return;
    hovering ? _life.stop() : _life.forward();
  }

  @override
  void dispose() {
    _show.dispose();
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final t = widget.toast;
    final (icon, tint) = switch (t.tone) {
      ToastTone.info => (Icons.notifications_none_rounded, scheme.primary),
      ToastTone.success => (Icons.check_circle_outline_rounded, const Color(0xFF4CD08A)),
      ToastTone.error => (Icons.error_outline_rounded, scheme.error),
    };
    final surface = dark ? Cinema.card : scheme.surfaceContainerHigh;
    final curve = CurvedAnimation(parent: _show, curve: Curves.easeOutCubic);

    // Grows into place and shrinks away, so the toasts below slide up instead of jumping.
    return AnimatedBuilder(
      animation: curve,
      // Clip only while moving, so the shadow isn't cut off once it's in place.
      builder: (context, child) => curve.value >= 1
          ? child!
          : ClipRect(
              child: Align(alignment: Alignment.topCenter, heightFactor: curve.value, child: child),
            ),
      child: FadeTransition(
        opacity: curve,
        child: SlideTransition(
          position: Tween(begin: const Offset(0.15, 0), end: Offset.zero).animate(curve),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: MouseRegion(
              onEnter: (_) => _hold(true),
              onExit: (_) => _hold(false),
              child: Material(
                color: surface,
                elevation: 10,
                shadowColor: Colors.black54,
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: dark ? scheme.outlineVariant : scheme.outline.withValues(alpha: 0.3)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Padding(
                            padding: EdgeInsets.zero,
                            child: Icon(icon, size: 20, color: tint),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Text(
                                t.text,
                                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface, height: 1.35),
                              ),
                            ),
                          ),
                          if (t.action != null) ...[
                            const SizedBox(width: 8),
                            TextButton(
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                foregroundColor: scheme.primary,
                                textStyle: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              onPressed: () {
                                t.onAction?.call();
                                _close();
                              },
                              child: Text(t.action!),
                            ),
                          ],
                          IconButton(
                            onPressed: _close,
                            icon: const Icon(Icons.close_rounded, size: 18),
                            color: dark ? Cinema.muted : scheme.onSurfaceVariant,
                            visualDensity: VisualDensity.compact,
                            splashRadius: 16,
                            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                            padding: EdgeInsets.zero,
                          ),
                        ],
                      ),
                    ),
                    // Time left, in the toast's colour; it stops while hovered.
                    AnimatedBuilder(
                      animation: _life,
                      builder: (context, _) => Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: 1 - _life.value,
                          child: Container(height: 2, color: tint.withValues(alpha: 0.7)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
