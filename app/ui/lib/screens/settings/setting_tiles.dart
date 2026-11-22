import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(text, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
    );
  }
}

class SwitchSetting extends StatelessWidget {
  const SwitchSetting({super.key, required this.setting, required this.title, this.subtitle});

  final Setting<bool> setting;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    return SwitchListTile(
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      value: settings.get(setting),
      onChanged: (v) => settings.set(setting, v),
    );
  }
}

/// A setting picked from a list, shown in a dialog.
class ChoiceSetting<T extends Object> extends StatelessWidget {
  const ChoiceSetting({
    super.key,
    required this.setting,
    required this.title,
    required this.choices,
    this.subtitle,
    this.icon,
  });

  final Setting<T> setting;
  final String title;
  final String? subtitle;
  final IconData? icon;

  /// Value and its label, in order.
  final List<(T, String)> choices;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final current = settings.get(setting);
    final label = choices.where((c) => c.$1 == current).map((c) => c.$2).firstOrNull ?? '$current';
    return ListTile(
      leading: icon == null ? null : Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle == null ? label : '$label · ${subtitle!}'),
      onTap: () async {
        final picked = await showDialog<T>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text(title),
            children: [
              for (final (value, text) in choices)
                ListTile(
                  leading: Icon(value == current ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                  title: Text(text),
                  onTap: () => Navigator.of(context).pop(value),
                ),
            ],
          ),
        );
        if (picked != null) await settings.set(setting, picked);
      },
    );
  }
}

/// Common languages for the preferred-language pickers.
const languageChoices = <(String, String)>[
  ('en', 'English'),
  ('ml', 'Malayalam'),
  ('hi', 'Hindi'),
  ('ta', 'Tamil'),
  ('te', 'Telugu'),
  ('kn', 'Kannada'),
  ('bn', 'Bengali'),
  ('mr', 'Marathi'),
  ('ur', 'Urdu'),
  ('es', 'Spanish'),
  ('fr', 'French'),
  ('de', 'German'),
  ('it', 'Italian'),
  ('pt', 'Portuguese'),
  ('ru', 'Russian'),
  ('ja', 'Japanese'),
  ('ko', 'Korean'),
  ('zh', 'Chinese'),
  ('ar', 'Arabic'),
  ('tr', 'Turkish'),
  ('id', 'Indonesian'),
  ('th', 'Thai'),
  ('vi', 'Vietnamese'),
];

String languageName(String code) => languageChoices.where((l) => l.$1 == code).map((l) => l.$2).firstOrNull ?? code;

/// An ordered list of preferred languages, stored as `ml,en`.
class LanguagesSetting extends StatelessWidget {
  const LanguagesSetting({super.key, required this.setting, required this.title, required this.emptyLabel});

  final Setting<String> setting;
  final String title;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final codes = settings.get(setting).split(',').where((c) => c.isNotEmpty).toList();
    return ListTile(
      title: Text(title),
      subtitle: Text(codes.isEmpty ? emptyLabel : codes.map(languageName).join(', ')),
      onTap: () async {
        final picked = await showDialog<List<String>>(
          context: context,
          builder: (_) => _LanguagesDialog(title: title, initial: codes),
        );
        if (picked != null) await settings.set(setting, picked.join(','));
      },
    );
  }
}

class _LanguagesDialog extends StatefulWidget {
  const _LanguagesDialog({required this.title, required this.initial});

  final String title;
  final List<String> initial;

  @override
  State<_LanguagesDialog> createState() => _LanguagesDialogState();
}

class _LanguagesDialogState extends State<_LanguagesDialog> {
  late final List<String> _order = [...widget.initial];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _order.isEmpty
                  ? 'Tap languages in order of preference.'
                  : 'In order: ${_order.map(languageName).join(' → ')}',
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  for (final (code, name) in languageChoices)
                    CheckboxListTile(
                      dense: true,
                      title: Text(name),
                      secondary: _order.contains(code)
                          ? CircleAvatar(radius: 12, child: Text('${_order.indexOf(code) + 1}'))
                          : null,
                      value: _order.contains(code),
                      onChanged: (on) => setState(() => on == true ? _order.add(code) : _order.remove(code)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => setState(_order.clear), child: const Text('Clear')),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(_order), child: const Text('Save')),
      ],
    );
  }
}
