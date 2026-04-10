Future<bool> pingRelay(String url) async {
  // On web, skip relay ping — we go straight to WebSocket connect
  return true;
}
