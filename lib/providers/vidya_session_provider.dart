import 'package:flutter/foundation.dart';

import '../services/vidya_connection.dart';

class VidyaSessionProvider extends ChangeNotifier {
  VidyaPlaybackSession? _connection;

  VidyaPlaybackSession? get connection => _connection;

  void setSession(VidyaPlaybackSession connection) {
    _connection = connection;
    notifyListeners();
  }

  void clearSession() {
    _connection = null;
    notifyListeners();
  }
}
