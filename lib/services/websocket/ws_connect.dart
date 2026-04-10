import 'dart:io';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

Future<WebSocketChannel> connectWebSocket(String url) async {
  final ws = await WebSocket.connect(url);
  return IOWebSocketChannel(ws);
}
