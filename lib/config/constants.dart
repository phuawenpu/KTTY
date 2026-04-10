const int kAppVersion = 7;
const String kAppBuildTime = String.fromEnvironment('BUILD_TIME', defaultValue: 'dev');

/// Relay URL for PWA. Passed at build time: --dart-define=RELAY_URL=<url>
/// Not shown to the user in the web interface.
const String kRelayUrl = String.fromEnvironment('RELAY_URL', defaultValue: '');

const int kTerminalMaxLines = 1000;
const int kDefaultCols = 80;
const int kDefaultRows = 24;
const int kPortraitTerminalFlex = 62;
const int kPortraitKeyboardFlex = 38;
const Duration kPingInterval = Duration(seconds: 5);
const Duration kPingTimeout = Duration(seconds: 10);
const Duration kReconnectInitial = Duration(seconds: 1);
const Duration kReconnectMax = Duration(seconds: 30);
