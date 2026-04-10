import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app.dart';
import 'services/crypto/native_crypto.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Block app if the platform's crypto is unavailable. On native this means
  // the libktty_ffi_crypto cdylib failed to load (missing from APK). On web
  // it means the WASM module didn't initialize.
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
