import 'package:flutter/foundation.dart';

import '../services/vidya_connection.dart';

class VidyaSessionProvider extends ChangeNotifier {
  VidyaConnection? _connection;

  VidyaConnection? get connection => _connection;

  void setSession(VidyaConnection connection) {
    _connection = connection;
    notifyListeners();
  }

  void clearSession() {
    _connection = null;
    notifyListeners();
  }
}
