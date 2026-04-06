import 'package:flutter/foundation.dart';
import '../models/connection_state.dart';

class SessionState extends ChangeNotifier {
  String _url = '';
  String _pin = '';
  ConnectionStatus _status = ConnectionStatus.disconnected;
  int _lastSeq = 0;

  String get url => _url;
  String get pin => _pin;
  ConnectionStatus get status => _status;
  int get lastSeq => _lastSeq;

  void setUrl(String url) {
    _url = url;
    notifyListeners();
  }

  void setPin(String pin) {
    _pin = pin;
    notifyListeners();
  }

  void setStatus(ConnectionStatus status) {
    _status = status;
    notifyListeners();
  }

  void updateSeq(int seq) {
    _lastSeq = seq;
  }

  void reset() {
    _status = ConnectionStatus.disconnected;
    _lastSeq = 0;
    notifyListeners();
  }
}
