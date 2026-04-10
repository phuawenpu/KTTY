import 'dart:js_interop';

/// Probe the relay's /health endpoint over HTTPS so the dashboard
/// connection indicator on the PWA reflects reality before the user
/// clicks Connect. Returns true if the relay responds with a 2xx.
///
/// Uses dart:js_interop to call window.fetch directly so we don't
/// have to pull in package:web. The CSP `connect-src` must whitelist
/// the relay's https origin (in addition to wss://) for this fetch
/// to work.

@JS('fetch')
external JSPromise<_JSResponse> _fetch(JSString url, JSAny options);

extension type _JSResponse._(JSObject _) implements JSObject {
  external bool get ok;
}

extension type _FetchInit._(JSObject _) implements JSObject {
  external factory _FetchInit({
    JSString method,
    JSString mode,
    JSString cache,
  });
}

Future<bool> pingRelay(String url) async {
  try {
    final httpUrl = url
        .replaceFirst('wss://', 'https://')
        .replaceFirst('ws://', 'http://')
        .replaceFirst('/ws', '/health');
    final init = _FetchInit(
      method: 'GET'.toJS,
      mode: 'cors'.toJS,
      cache: 'no-store'.toJS,
    );
    final response = await _fetch(httpUrl.toJS, init).toDart;
    return response.ok;
  } catch (_) {
    return false;
  }
}
