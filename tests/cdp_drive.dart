// Minimal Chrome DevTools Protocol driver for e2e verification of
// the KTTY PWA. Discovers the first tab via the CDP HTTP endpoint,
// opens a WebSocket to it, runs a scripted sequence:
//
//   1. Wait for the dashboard to render.
//   2. Read the console for any leaked envelope fragments.
//   3. Screenshot the page (base64, returned on stdout).
//
// This does NOT drive a real handshake — that requires typing a PIN
// into the UI and is brittle to run from a test harness. We just
// confirm the page loads without the new code path crashing and
// that nothing resembling a raw envelope appears on the screen.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final cdpHost = args.isNotEmpty ? args[0] : '127.0.0.1:9222';

  // 1. Find a tab.
  final tabsReq = await HttpClient().getUrl(Uri.parse('http://$cdpHost/json'));
  final tabsResp = await tabsReq.close();
  final tabsBody = await tabsResp.transform(utf8.decoder).join();
  final tabs = jsonDecode(tabsBody) as List;
  if (tabs.isEmpty) {
    stderr.writeln('[cdp-drive] No tabs');
    exit(1);
  }
  final wsUrl = tabs.first['webSocketDebuggerUrl'] as String;
  stderr.writeln('[cdp-drive] Connecting to $wsUrl');

  final ws = await WebSocket.connect(wsUrl);
  int nextId = 1;
  final replies = <int, Completer<Map<String, dynamic>>>{};
  final consoleMessages = <String>[];

  ws.listen((raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    if (msg['method'] == 'Runtime.consoleAPICalled') {
      final args = msg['params']?['args'] as List? ?? [];
      final line = args.map((a) => (a as Map)['value']?.toString() ?? '').join(' ');
      consoleMessages.add(line);
      stderr.writeln('[console] $line');
    }
    final id = msg['id'] as int?;
    if (id != null && replies.containsKey(id)) {
      replies.remove(id)!.complete(msg);
    }
  });

  Future<Map<String, dynamic>> send(String method, [Map<String, dynamic>? params]) {
    final id = nextId++;
    final c = Completer<Map<String, dynamic>>();
    replies[id] = c;
    ws.add(jsonEncode({'id': id, 'method': method, if (params != null) 'params': params}));
    return c.future.timeout(const Duration(seconds: 10));
  }

  // Subscribe to console events.
  await send('Runtime.enable');
  await send('Page.enable');

  // 2. Wait for page load.
  await Future.delayed(const Duration(seconds: 3));

  // 3. Evaluate: does body contain anything that looks like a leaked
  //    envelope? We look for literal `"payload"` tokens in visible DOM.
  final eval = await send('Runtime.evaluate', {
    'expression':
        "document.body.innerText.includes('\"payload\"') ? 'LEAK' : 'CLEAN'",
    'returnByValue': true,
  });
  final result = eval['result']?['result']?['value'];
  stderr.writeln('[cdp-drive] DOM leak check: $result');

  // 4. Screenshot.
  final shot = await send('Page.captureScreenshot', {'format': 'png'});
  final png = shot['result']?['data'] as String?;
  if (png != null) {
    final file = File('/tmp/ktty-dashboard.png');
    await file.writeAsBytes(base64Decode(png));
    stderr.writeln('[cdp-drive] Screenshot saved to ${file.path}');
  }

  // 5. Also dump the page title and URL.
  final title = await send('Runtime.evaluate', {
    'expression': 'document.title',
    'returnByValue': true,
  });
  stderr.writeln('[cdp-drive] Title: ${title['result']?['result']?['value']}');

  // 6. Report results.
  stderr.writeln('[cdp-drive] Console lines captured: ${consoleMessages.length}');
  for (final line in consoleMessages) {
    if (line.contains('payload') || line.contains('Dropping')) {
      stderr.writeln('[cdp-drive] [notable] $line');
    }
  }

  await ws.close();
  print(jsonEncode({
    'dom_leak': result,
    'title': title['result']?['result']?['value'],
    'console_count': consoleMessages.length,
  }));
  exit(0);
}
