import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app.dart';
import 'services/crypto/native_crypto.dart';
import 'src/rust/frb_generated.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Rust FFI is only available on native platforms (Android/iOS/desktop).
  // On web, crypto is handled by WASM module loaded in index.html.
  if (!kIsWeb) {
    await RustLib.init();
  }

  // Block app if crypto is not available
  if (!NativeCrypto.isCryptoAvailable) {
    runApp(const _CryptoErrorApp());
    return;
  }

  // Lock to portrait by default; landscape via manual toggle only
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  // Immersive mode — hide status and navigation bars
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  runApp(const KttyApp());
}

/// Shown when crypto module failed to load (e.g. WASM not available).
class _CryptoErrorApp extends StatelessWidget {
  const _CryptoErrorApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const Scaffold(
        backgroundColor: Color(0xFF1A1A2E),
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, color: Colors.red, size: 48),
                SizedBox(height: 16),
                Text(
                  'Crypto Module Unavailable',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'The cryptography engine failed to load.\n'
                  'This browser may not support WebAssembly.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 14),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
