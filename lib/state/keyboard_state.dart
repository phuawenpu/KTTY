import 'package:flutter/foundation.dart';

class KeyboardState extends ChangeNotifier {
  int _activeLayer = 0;
  bool _ctrlActive = false;
  bool _shiftActive = false;
  bool _capsLock = false;

  int get activeLayer => _activeLayer;
  bool get ctrlActive => _ctrlActive;
  bool get shiftActive => _shiftActive;
  bool get capsLock => _capsLock;

  bool get isUpperCase => _shiftActive || _capsLock;

  void setLayer(int layer) {
    _activeLayer = layer.clamp(0, 2);
    notifyListeners();
  }

  void toggleCtrl() {
    _ctrlActive = !_ctrlActive;
    notifyListeners();
  }

  void toggleShift() {
    _shiftActive = !_shiftActive;
    notifyListeners();
  }

  void toggleCapsLock() {
    _capsLock = !_capsLock;
    notifyListeners();
  }

  void clearModifiers() {
    _ctrlActive = false;
    _shiftActive = false;
    notifyListeners();
  }
}
