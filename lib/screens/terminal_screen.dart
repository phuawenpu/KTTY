import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../config/constants.dart';
import '../models/connection_state.dart';
import '../models/viewport_mode.dart';
import '../state/session_state.dart';
import '../state/viewport_state.dart';
import '../services/terminal/terminal_service.dart';
import '../services/websocket/websocket_service.dart';
import '../widgets/terminal/terminal_container.dart';
import '../widgets/terminal/connection_indicator.dart';
import '../widgets/keyboard/custom_keyboard.dart';

class TerminalScreen extends StatefulWidget {
  final TerminalService terminalService;
  final WebSocketService wsService;

  const TerminalScreen({
    super.key,
    required this.terminalService,
    required this.wsService,
  });

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final _terminalKey = GlobalKey<TerminalContainerState>();
  // Persisted font size: updated only on scale-end / explicit zoom
  // buttons / auto-size. Live pinch feedback goes through the
  // TerminalContainer's fontSizeNotifier instead, so the full screen
  // doesn't rebuild per pinch frame.
  double _displayFontSize = 14.0;

  // Speech-to-text
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _speechAvailable = false;
  bool _isListening = false;

  // PWA: collapsible built-in keyboard (default: shown)
  bool _builtInKeyboardVisible = true;

  // Smart-invert "light mode" for the terminal. When true the
  // TerminalContainer is wrapped in a ColorFiltered widget that does
  // invert + hue-rotate(180°), which flips white↔black while keeping
  // saturated colours (red errors, green prompts, blue links, etc.)
  // recognisably the same colour. Toggled by the appBar button.
  bool _invertedTheme = false;

  // Composition of `invert(1)` then `hue-rotate(180°)`, derived from
  // the CSS spec's hue-rotate matrix with sRGB luma weights
  // (R=0.213, G=0.715, B=0.072). Re-derive analytically if you want
  // to tweak — these are the standard "smart invert" coefficients.
  // The 5th column is the constant offset; for Flutter's
  // ColorFilter.matrix the colour channels expect 0–255 there.
  static const List<double> _smartInvertMatrix = <double>[
     0.574, -1.430, -0.144, 0, 255,
    -0.426, -0.430, -0.144, 0, 255,
    -0.426, -1.430,  0.856, 0, 255,
     0,      0,      0,     1,   0,
  ];

  Widget _maybeInvert(Widget child) {
    if (!_invertedTheme) return child;
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(_smartInvertMatrix),
      child: child,
    );
  }

  void _toggleInvert() {
    setState(() => _invertedTheme = !_invertedTheme);
  }

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final t = widget.terminalService.terminal;
      if (t.viewWidth > 0 && t.viewHeight > 0) {
        print('[KTTY] Post-frame resize: ${t.viewWidth}x${t.viewHeight}');
        widget.terminalService.sendResize(t.viewWidth, t.viewHeight);
      }
    });
    if (!kIsWeb) _initSpeech();
  }

  Future<void> _initSpeech() async {
    _speechAvailable = await _speech.initialize(
      onError: (error) {
        print('[KTTY] Speech error: ${error.errorMsg}');
        setState(() => _isListening = false);
      },
      onStatus: (status) {
        print('[KTTY] Speech status: $status');
        if (status == 'done' || status == 'notListening') {
          setState(() => _isListening = false);
        }
      },
    );
    print('[KTTY] Speech available: $_speechAvailable');
  }

  void _toggleSpeech() {
    if (!_speechAvailable) return;

    if (_isListening) {
      _speech.stop();
      setState(() => _isListening = false);
    } else {
      setState(() => _isListening = true);
      _speech.listen(
        onResult: (result) {
          if (result.finalResult) {
            final text = result.recognizedWords;
            if (text.isNotEmpty) {
              widget.terminalService.sendText(text);
            }
          }
        },
        listenMode: stt.ListenMode.dictation,
        cancelOnError: true,
      );
    }
  }

  void _onKeyPressed(String value) {
    widget.terminalService.terminal.textInput(value);
  }

  void _disconnect() {
    widget.terminalService.detach();
    widget.wsService.disconnect();
    context.read<SessionState>().setStatus(ConnectionStatus.disconnected);
    Navigator.pushReplacementNamed(context, '/dashboard');
  }

  /// Show a popup with end-to-end keystroke latency, traffic counters,
  /// session age, and build/version info. Reads from
  /// `widget.terminalService.stats` and the live SessionState. The
  /// dialog rebuilds itself once a second so the user can watch the
  /// numbers move while typing.
  void _showStatsDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return _StatsDialog(
          stats: widget.terminalService.stats,
          session: context.read<SessionState>(),
        );
      },
    );
  }

  void _toggleViewport() {
    final vs = context.read<ViewportState>();

    if (vs.mode == ViewportMode.portrait) {
      vs.setResizing(true);
      vs.setMode(ViewportMode.landscape);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      vs.setResizing(true);
      vs.setMode(ViewportMode.portrait);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    }

    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        vs.setResizing(false);
      }
    });
  }

  String _getSelectedText() {
    return widget.terminalService.getSelectedText();
  }

  void _toggleBuiltInKeyboard() {
    setState(() => _builtInKeyboardVisible = !_builtInKeyboardVisible);
  }

  @override
  Widget build(BuildContext context) {
    final status = context.watch<SessionState>().status;
    final vs = context.watch<ViewportState>();
    final isPortrait = vs.mode == ViewportMode.portrait;
    final keyboardDisabled = status != ConnectionStatus.connected &&
        status != ConnectionStatus.syncing;

    // Allow collapsing the built-in keyboard on both web and Android
    final showBuiltInKeyboard = isPortrait && _builtInKeyboardVisible;

    return SafeArea(
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              // The KTTY title now carries the connection status via its
              // own colour (see KttyTitle). The dot to the right is a
              // small visual anchor; the previous "Connected" /
              // "Disconnected" text label was removed because it
              // overlapped the font-size +/- buttons on small phones.
              KttyTitle(),
              SizedBox(width: 6),
              ConnectionIndicator(),
            ],
          ),
          backgroundColor: const Color(0xFF16213E),
          toolbarHeight: 32,
          titleTextStyle: const TextStyle(fontSize: 13),
          // Drop the leading icon space so the title sits flush left and
          // we get a few extra pixels of action-row real estate.
          leading: Padding(
            padding: const EdgeInsets.only(left: 8, top: 4, bottom: 4),
            child: Image.asset('assets/ktty_logo.png', height: 18),
          ),
          leadingWidth: 32,
          actions: [
            // Font size controls
            _buildHeaderButton(Icons.remove, () {
              _terminalKey.currentState?.zoomOut();
            }),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: _FontSizeReadout(
                fallback: _displayFontSize,
                notifier: _terminalKey.currentState?.fontSizeNotifier,
              ),
            ),
            _buildHeaderButton(Icons.add, () {
              _terminalKey.currentState?.zoomIn();
            }),
            const SizedBox(width: 6),
            // Toggle built-in keyboard
            if (isPortrait)
              IconButton(
                icon: Icon(
                  _builtInKeyboardVisible
                      ? Icons.keyboard_hide
                      : Icons.keyboard,
                  size: 18,
                ),
                onPressed: _toggleBuiltInKeyboard,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: _builtInKeyboardVisible
                    ? 'Hide keyboard'
                    : 'Show keyboard',
              ),
            if (isPortrait) const SizedBox(width: 6),
            // Smart-invert (light/dark) toggle for the terminal panel
            IconButton(
              icon: Icon(
                _invertedTheme ? Icons.dark_mode : Icons.light_mode,
                size: 18,
              ),
              onPressed: _toggleInvert,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              tooltip: _invertedTheme
                  ? 'Switch to dark terminal'
                  : 'Switch to light terminal',
            ),
            const SizedBox(width: 6),
            // Stats / info popup
            IconButton(
              icon: const Icon(Icons.info_outline, size: 18),
              onPressed: _showStatsDialog,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              tooltip: 'Session stats',
            ),
            const SizedBox(width: 6),
            // Disconnect button
            IconButton(
              icon: const Icon(Icons.exit_to_app, size: 18),
              onPressed: _disconnect,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              tooltip: 'Disconnect',
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(
                isPortrait
                    ? Icons.screen_rotation
                    : Icons.stay_current_portrait,
                size: 18,
              ),
              onPressed: _toggleViewport,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: showBuiltInKeyboard
            ? Column(
                children: [
                  Expanded(
                    flex: kPortraitTerminalFlex,
                    child: _maybeInvert(
                      TerminalContainer(
                        key: _terminalKey,
                        terminal: widget.terminalService.terminal,
                        controller: widget.terminalService.controller,
                        onFontSizeChanged: (size) {
                          setState(() => _displayFontSize = size);
                        },
                        onWordTapped: (word) {
                          widget.terminalService.sendText(word);
                        },
                        onPinchStart: widget.terminalService.notifyPinchStart,
                        onPinchEnd: widget.terminalService.notifyPinchEnd,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: kPortraitKeyboardFlex,
                    child: CustomKeyboard(
                      onKeyPressed: _onKeyPressed,
                      disabled: keyboardDisabled,
                      viewportMode: vs.mode,
                      onGetSelectedText: _getSelectedText,
                      onPaste: (text) {
                        print('[KTTY] Pasting ${text.length} chars');
                        widget.terminalService.sendText(text);
                      },
                      onMicPressed: kIsWeb ? null : _toggleSpeech,
                      isListening: _isListening,
                      onHideKeyboard: _toggleBuiltInKeyboard,
                    ),
                  ),
                ],
              )
            : Padding(
                padding: const EdgeInsets.all(4),
                child: _maybeInvert(
                  TerminalContainer(
                    key: _terminalKey,
                    terminal: widget.terminalService.terminal,
                    controller: widget.terminalService.controller,
                    hardwareKeyboardOnly: true,
                    onFontSizeChanged: (size) {
                      setState(() => _displayFontSize = size);
                    },
                    onWordTapped: (word) {
                      widget.terminalService.sendText(word);
                    },
                    onPinchStart: widget.terminalService.notifyPinchStart,
                    onPinchEnd: widget.terminalService.notifyPinchEnd,
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildHeaderButton(IconData icon, VoidCallback onTap) {
    return Material(
      color: const Color(0xFF2A2A4A).withValues(alpha: 0.8),
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, color: Colors.white54, size: 14),
        ),
      ),
    );
  }
}

/// Live-updating session stats popup. Rebuilds once a second so the
/// numbers tick over while you watch them; cancels its timer when
/// dismissed. Reads RTT samples + byte counters from
/// [TerminalService.stats] and the connection status from
/// [SessionState].
class _StatsDialog extends StatefulWidget {
  final TerminalStats stats;
  final SessionState session;

  const _StatsDialog({required this.stats, required this.session});

  @override
  State<_StatsDialog> createState() => _StatsDialogState();
}

class _StatsDialogState extends State<_StatsDialog> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  String _fmtMs(num? ms) => ms == null ? '—' : '${ms.toStringAsFixed(0)} ms';

  String _fmtUptime(int? seconds) {
    if (seconds == null) return '—';
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}m ${seconds % 60}s';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    return '${h}h ${m}m';
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontFamily: 'RobotoMono',
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String heading) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(
        heading,
        style: const TextStyle(
          color: Colors.blueAccent,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.stats;
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFF4A4A6A), width: 1),
      ),
      title: const Text(
        'Session stats',
        style: TextStyle(color: Colors.white, fontSize: 16),
      ),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _section('KEYSTROKE LATENCY (END-TO-END)'),
            _row('Last', _fmtMs(s.lastRttMs)),
            _row('Average (last ${s.sampleCount})', _fmtMs(s.averageRttMs)),
            _row('Min', _fmtMs(s.minRttMs)),
            _row('Max', _fmtMs(s.maxRttMs)),
            _row('Samples', '${s.sampleCount} / ${s.capacity}'),
            _section('TRAFFIC'),
            _row('Bytes sent', _fmtBytes(s.bytesSent)),
            _row('Bytes received', _fmtBytes(s.bytesReceived)),
            _row('Messages sent', '${s.messagesSent}'),
            _row('Messages received', '${s.messagesReceived}'),
            _section('SESSION'),
            _row('Status', widget.session.status.name),
            _row('Uptime', _fmtUptime(s.sessionAgeSeconds)),
            _row('Build', kAppBuildTime == 'dev' ? 'dev' : kAppBuildTime),
            _row('App version', 'v$kAppVersion'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close', style: TextStyle(color: Colors.blueAccent)),
        ),
      ],
    );
  }
}

/// Tiny AppBar readout that rebuilds from the TerminalContainer's
/// fontSizeNotifier (not the screen's own setState). During a pinch
/// this means only this little text node rebuilds per frame, not the
/// entire TerminalScreen subtree — which is what made TUI zoom feel
/// like it was hanging.
///
/// Uses [fallback] while the notifier is not yet available (first
/// frame, before the GlobalKey has attached).
class _FontSizeReadout extends StatelessWidget {
  final double fallback;
  final ValueNotifier<double>? notifier;

  const _FontSizeReadout({required this.fallback, required this.notifier});

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: Colors.white38, fontSize: 10);
    if (notifier == null) {
      return Text('${fallback.round()}', style: style);
    }
    return ValueListenableBuilder<double>(
      valueListenable: notifier!,
      builder: (_, size, __) => Text('${size.round()}', style: style),
    );
  }
}
