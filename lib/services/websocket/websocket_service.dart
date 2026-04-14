import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show VoidCallback, kIsWeb;
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../config/constants.dart';
import '../crypto/pin_utils.dart';
import 'ws_connect.dart' if (dart.library.js_interop) 'ws_connect_web.dart'
    as ws_connect;
import '../crypto/handshake_service.dart';
import '../crypto/crypto_service.dart';

typedef ConnectionStateCallback = void Function(bool connected);

class WebSocketService {
  WebSocketChannel? _channel;
  final _messageController = StreamController<String>.broadcast();
  StreamSubscription? _subscription;
  CryptoService? _crypto;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  String? _lastUrl;
  String? _lastPin;
  bool _autoReconnectEnabled = false;
  String? _relayAuthToken;
  String? _sessionId;

  ConnectionStateCallback? onConnectionChanged;
  VoidCallback? onReconnected;

  Stream<String> get messages => _messageController.stream;
  bool get isConnected => _channel != null;
  bool get isEncrypted => _crypto != null;
  String? get sessionId => _sessionId;

  String _deriveSessionId(Uint8List sessionKey) {
    final buf = StringBuffer();
    for (final b in sessionKey.take(8)) {
      buf.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }

  Future<void> connect(String url) async {
    _cancelReconnect();
    _lastUrl = url;
    _cleanupChannel();

    _channel = await ws_connect.connectWebSocket(url);

    _autoReconnectEnabled = true;

    _subscription = _channel!.stream.listen(
      (data) {
        final str = data as String;
        print('[KTTY-WS] Received: ${str.substring(0, str.length.clamp(0, 100))}');

        // Intercept relay auth token
        if (str.contains('"type"') && str.contains('"auth"')) {
          try {
            final json = jsonDecode(str) as Map<String, dynamic>;
            if (json['type'] == 'auth' && json['token'] != null) {
              _relayAuthToken = json['token'] as String;
              print('[KTTY-WS] Received relay auth token');
              return; // Don't forward auth messages to terminal
            }
          } catch (_) {}
        }

        _messageController.add(str);
      },
      onError: (error) {
        print('[KTTY-WS] Stream error: $error');
        _messageController.addError(error);
        _handleDisconnect();
      },
      onDone: () {
        print('[KTTY-WS] Stream closed');
        _handleDisconnect();
      },
    );
  }

  void _handleDisconnect() {
    print('[KTTY-WS] Disconnected (autoReconnect=$_autoReconnectEnabled, hasUrl=${_lastUrl != null}, hasPin=${_lastPin != null})');
    _channel = null;
    _crypto = null;
    _sessionId = null;
    _relayAuthToken = null;
    onConnectionChanged?.call(false);
    if (_autoReconnectEnabled) {
      _scheduleReconnect();
    } else {
      print('[KTTY-WS] Auto-reconnect disabled, not reconnecting');
    }
  }

  /// Called by app lifecycle observer to reconnect after returning from background.
  void attemptReconnect() {
    if (_lastUrl == null || _lastPin == null) return;
    _autoReconnectEnabled = true;
    _reconnectAttempts = 0;
    _scheduleReconnect();
  }

  /// Suppress auto-reconnect while app is in background.
  /// Android kills the WS immediately; reconnecting in background fails
  /// (DNS/network suspended). The app will reconnect on resume instead.
  void suppressReconnect() {
    _autoReconnectEnabled = false;
    _cancelReconnect();
    print('[KTTY-WS] Reconnect suppressed (backgrounded)');
  }

  /// Close the WS channel without clearing credentials.
  /// Used by background timer to release resources while preserving reconnect ability.
  void backgroundClose() {
    print('[KTTY-WS] Background close (preserving credentials)');
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _crypto = null;
    _sessionId = null;
    _relayAuthToken = null;
  }

  void _scheduleReconnect() {
    if (_lastUrl == null || _lastPin == null) return;
    _cancelReconnect();

    final delay = Duration(
      milliseconds: min(
        kReconnectInitial.inMilliseconds * pow(2, _reconnectAttempts).toInt(),
        kReconnectMax.inMilliseconds,
      ),
    );
    _reconnectAttempts++;

    print('[KTTY-WS] Scheduling reconnect in ${delay.inSeconds}s (attempt $_reconnectAttempts)');
    _reconnectTimer = Timer(delay, () async {
      try {
        print('[KTTY-WS] Reconnecting...');
        await connect(_lastUrl!);
        await performHandshake(_lastPin!);
        _reconnectAttempts = 0;
        onConnectionChanged?.call(true);
        onReconnected?.call();
      } catch (e) {
        print('[KTTY-WS] Reconnect failed: $e');
        if (_autoReconnectEnabled) {
          _scheduleReconnect();
        }
      }
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// Join room, perform ML-KEM handshake, establish encrypted session.
  Future<void> performHandshake(String pin) async {
    _lastPin = pin;
    final derivedKey = await PinUtils.deriveKey(pin);
    final roomId = await PinUtils.hashPin(pin);

    // 1. Send join
    print('[KTTY-WS] Room ID: $roomId');
    sendJson({'action': 'join', 'room_id': roomId});

    // 2. Wait for agent's boot signal and then handshake offer (ML-KEM public key)
    print('[KTTY-WS] Waiting for agent handshake offer (15s)...');
    String? mlkemPubKeyB64;

    await messages.firstWhere((msg) {
      try {
        final json = jsonDecode(msg) as Map<String, dynamic>;
        final type = json['type'] as String?;

        // Agent sends handshake offer with ML-KEM encapsulation key
        if (type == 'handshake' && json['mlkem_pub_key'] != null) {
          mlkemPubKeyB64 = json['mlkem_pub_key'] as String;
          print('[KTTY-WS] Received ML-KEM public key');
          return true;
        }

        // Boot signal means agent is alive, keep waiting for handshake
        if (type == 'boot') {
          print('[KTTY-WS] Agent sent boot signal, waiting for handshake...');
          return false;
        }

        print('[KTTY-WS] Waiting... got type=$type');
        return false;
      } catch (_) {
        return false;
      }
    }).timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw Exception(
        'No agent found. Check PIN and ensure the host agent is running.',
      ),
    );

    // 3. Encapsulate shared secret using agent's ML-KEM public key
    final ekBytes = Uint8List.fromList(base64Decode(mlkemPubKeyB64!));
    print('[KTTY-WS] Encapsulating shared secret (ML-KEM 768)...');
    final result = await HandshakeService.encapsulate(ekBytes);

    // 4. Send ciphertext back to agent
    sendJson({
      'type': 'handshake',
      'mlkem_ciphertext': base64Encode(result.ciphertext),
    });
    print('[KTTY-WS] Sent ML-KEM ciphertext to agent');

    // 5. Wait for agent's HMAC verification
    print('[KTTY-WS] Waiting for HMAC verification (10s)...');
    await messages.firstWhere((msg) {
      try {
        final json = jsonDecode(msg) as Map<String, dynamic>;
        final type = json['type'] as String?;
        if (type == 'handshake' && json['hmac'] != null) {
          final hmacB64 = json['hmac'] as String;
          _pendingHmacVerification = (derivedKey, result.sharedSecret, hmacB64);
          return true;
        }
        return false;
      } catch (_) {
        return false;
      }
    }).timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw Exception('Handshake HMAC timeout'),
    );

    // 6. Verify HMAC and establish encrypted session
    final (key, ss, hmacB64) = _pendingHmacVerification!;
    _pendingHmacVerification = null;
    final hmacBytes = Uint8List.fromList(base64Decode(hmacB64));
    final valid = await HandshakeService.verifyHmac(key, ss, hmacBytes);
    if (!valid) {
      throw Exception('HMAC verification failed — possible MITM attack');
    }

    _crypto = CryptoService(ss);
    _sessionId = _deriveSessionId(ss);
    print('[KTTY-WS] Handshake verified, encrypted mode');
  }

  // Temp storage for HMAC data between stream callback and async verification
  (Uint8List, Uint8List, String)? _pendingHmacVerification;

  /// Send an encrypted envelope.
  Future<void> sendEncrypted(int seq, String type, List<int> payload) async {
    if (_crypto == null) {
      throw StateError('Handshake not completed');
    }
    if (_sessionId == null) {
      throw StateError('Session ID not established');
    }
    final encrypted = await _crypto!.encrypt(payload);
    sendJson({
      'seq': seq,
      'session_id': _sessionId,
      'type': type,
      'payload': base64Encode(encrypted),
    });
  }

  /// Decrypt a received envelope payload.
  Future<Uint8List> decryptPayload(String base64Payload) async {
    if (_crypto == null) {
      throw StateError('Handshake not completed');
    }
    final packed = Uint8List.fromList(base64Decode(base64Payload));
    return _crypto!.decrypt(packed);
  }

  /// Send sync request on reconnect.
  Future<void> sendSyncRequest(int lastSeq) async {
    if (_crypto == null) {
      throw StateError('Handshake not completed');
    }
    if (_sessionId == null) {
      throw StateError('Session ID not established');
    }
    final payload = utf8.encode(jsonEncode({
      'last_seq': lastSeq,
      'session_id': _sessionId,
    }));
    await sendEncrypted(lastSeq, 'sync_req', payload);
  }

  void send(String data) {
    _channel?.sink.add(data);
  }

  void sendJson(Map<String, dynamic> json) {
    // Include relay auth token if we have one (skip for join/handshake messages)
    if (_relayAuthToken != null && json['action'] != 'join') {
      json['auth'] = _relayAuthToken;
    }
    send(jsonEncode(json));
  }

  void _cleanupChannel() {
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _crypto = null;
    _sessionId = null;
    _relayAuthToken = null;
  }

  void disconnect() {
    _autoReconnectEnabled = false;
    _cancelReconnect();
    // Notify agent before closing
    try {
      sendJson({'type': 'disconnect'});
    } catch (_) {}
    _cleanupChannel();
    _crypto = null;
    _sessionId = null;
    _relayAuthToken = null;
    _lastUrl = null;
    _lastPin = null;
  }

  void dispose() {
    disconnect();
    _messageController.close();
  }
}
