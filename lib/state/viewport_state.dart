import 'package:flutter/foundation.dart';
import '../models/viewport_mode.dart';

class ViewportState extends ChangeNotifier {
  ViewportMode _mode = ViewportMode.portrait;
  bool _isResizing = false;

  ViewportMode get mode => _mode;
  bool get isResizing => _isResizing;

  void setMode(ViewportMode mode) {
    _mode = mode;
    notifyListeners();
  }

  void setResizing(bool resizing) {
    _isResizing = resizing;
    notifyListeners();
  }

  void toggleMode() {
    _mode = _mode == ViewportMode.portrait
        ? ViewportMode.landscape
        : ViewportMode.portrait;
    notifyListeners();
  }
}
