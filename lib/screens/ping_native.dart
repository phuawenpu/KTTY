import 'dart:io';

Future<bool> pingRelay(String url) async {
  try {
    final httpUrl = url
        .replaceFirst('wss://', 'https://')
        .replaceFirst('ws://', 'http://')
        .replaceFirst('/ws', '/');
    final uri = Uri.parse(httpUrl);
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 5);
    final request = await client.getUrl(uri);
    final response = await request.close();
    client.close();
    return response.statusCode < 500;
  } catch (_) {
    return false;
  }
}
