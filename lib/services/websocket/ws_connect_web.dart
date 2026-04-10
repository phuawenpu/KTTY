import 'package:web_socket_channel/web_socket_channel.dart';

Future<WebSocketChannel> connectWebSocket(String url) async {
  return WebSocketChannel.connect(Uri.parse(url));
}
