import 'package:couchmates_core/couchmates_core.dart';

/// The Hub's [Chat], running while the user is signed in, plus what the
/// bubble's chat tab shows.
class AppChat extends Chat {
  AppChat({required this.session, ChatConnector? connect})
    : super(
        connect: connect ?? connectChatSocket,
        hub: () => session.status == SessionStatus.signedIn ? session.hub : null,
        me: () => session.config?.user.id,
      ) {
    session.addListener(_onSession);
    _onSession();
  }

  final HubSession session;

  /// This user's id, once signed in.
  String? get me => session.config?.user.id;

  /// The bubble shows the chat tab (rather than who's watching).
  bool get showing => _showing;
  bool _showing = false;
  set showing(bool value) {
    if (value == _showing) return;
    _showing = value;
    notifyListeners();
  }

  /// The conversation picked in the chat tab; null shows the list.
  String? get selected => _selected;
  String? _selected;
  set selected(String? id) {
    if (id == _selected) return;
    _selected = id;
    notifyListeners();
  }

  /// Bumped to ask the bubble to open on the chat tab.
  int get openRequests => _openRequests;
  int _openRequests = 0;

  /// Opens the bubble on the private chat with [person].
  void openWith(Person person) {
    _selected = directWith(person);
    _showing = true;
    _openRequests++;
    notifyListeners();
  }

  void _onSession() {
    if (session.status == SessionStatus.signedIn && session.config != null) {
      start();
    } else if (session.status != SessionStatus.signedIn) {
      stop();
      _selected = null;
      _showing = false;
      clear();
    }
  }

  @override
  void dispose() {
    session.removeListener(_onSession);
    super.dispose();
  }
}
