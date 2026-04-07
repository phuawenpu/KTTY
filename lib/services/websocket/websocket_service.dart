import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import '../../config/constants.dart';
import '../crypto/pin_utils.dart';
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

  ConnectionStateCallback? onConnectionChanged;

  Stream<String> get messages => _messageController.stream;
  bool get isConnected => _channel != null;
  bool get isEncrypted => _crypto != null;

  Future<void> connect(String url) async {
    _cancelReconnect();
    _lastUrl = url;
    _cleanupChannel();

    final uri = Uri.parse(url);

    // Use IOWebSocketChannel with cert override for IP-based WSS connections
    if (uri.scheme == 'wss') {
      final client = HttpClient()
        ..badCertificateCallback = (cert, host, port) => true;
      final ws = await WebSocket.connect(
        url,
        customClient: client,
      );
      _channel = IOWebSocketChannel(ws);
    } else {
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;
    }

    _subscription = _channel!.stream.listen(
      (data) {
        print('[KTTY-WS] Received: ${(data as String).substring(0, (data as String).length.clamp(0, 100))}');
        _messageController.add(data as String);
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
    print('[KTTY-WS] Disconnected');
    _channel = null;
    onConnectionChanged?.call(false);
    _scheduleReconnect();
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
      } catch (e) {
        print('[KTTY-WS] Reconnect failed: $e');
      }
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// Join room and establish connection.
  /// TODO: Re-enable ML-KEM handshake once flutter_rust_bridge crypto FFI is implemented.
  Future<void> performHandshake(String pin) async {
    _lastPin = pin;
    final roomId = await PinUtils.hashPin(pin);

    // Send join
    print('[KTTY-WS] Sending join with room_id: ${roomId.substring(0, 8)}...');
    sendJson({'action': 'join', 'room_id': roomId});

    // Plain-text mode — no encryption
    print('[KTTY-WS] Plain-text mode (no encryption)');
    _crypto = null;

    // Wait briefly for agent to detect us and start sending
    await Future.delayed(const Duration(seconds: 2));
    print('[KTTY-WS] Ready for PTY data');
  }

  /// Send an encrypted envelope.
  Future<void> sendEncrypted(int seq, String type, List<int> payload) async {
    if (_crypto == null) {
      throw StateError('Handshake not completed');
    }
    final encrypted = await _crypto!.encrypt(payload);
    sendJson({
      'seq': seq,
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
    final payload = utf8.encode(jsonEncode({'last_seq': lastSeq}));
    if (_crypto != null) {
      await sendEncrypted(lastSeq, 'sync_req', payload);
    }
  }

  void send(String data) {
    _channel?.sink.add(data);
  }

  void sendJson(Map<String, dynamic> json) {
    send(jsonEncode(json));
  }

  void _cleanupChannel() {
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
  }

  void disconnect() {
    _cancelReconnect();
    _cleanupChannel();
    _crypto = null;
    _lastUrl = null;
    _lastPin = null;
  }

  void dispose() {
    disconnect();
    _messageController.close();
  }
}
