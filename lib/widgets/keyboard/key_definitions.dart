class KeyDef {
  final String label;
  final String value;
  final String? swipeUpValue;
  final String? swipeDownValue;
  final String? swipeLeftValue;
  final String? swipeRightValue;
  final double flex;

  const KeyDef({
    required this.label,
    required this.value,
    this.swipeUpValue,
    this.swipeDownValue,
    this.swipeLeftValue,
    this.swipeRightValue,
    this.flex = 1.0,
  });
}

// Layer 0: QWERTY Alphabetical
const List<List<KeyDef>> kLayer0 = [
  // Row 1
  [
    KeyDef(label: 'Q', value: 'q', swipeDownValue: '\x11'), // Ctrl+Q
    KeyDef(label: 'W', value: 'w', swipeDownValue: '\x17'), // Ctrl+W
    KeyDef(label: 'E', value: 'e', swipeDownValue: '\x05'), // Ctrl+E
    KeyDef(label: 'R', value: 'r', swipeDownValue: '\x12'), // Ctrl+R
    KeyDef(label: 'T', value: 't', swipeDownValue: '\x14'), // Ctrl+T
    KeyDef(label: 'Y', value: 'y', swipeDownValue: '\x19'), // Ctrl+Y
    KeyDef(label: 'U', value: 'u', swipeDownValue: '\x15'), // Ctrl+U
    KeyDef(label: 'I', value: 'i', swipeDownValue: '\x09'), // Ctrl+I (Tab)
    KeyDef(label: 'O', value: 'o', swipeDownValue: '\x0F'), // Ctrl+O
    KeyDef(label: 'P', value: 'p', swipeDownValue: '\x10'), // Ctrl+P
  ],
  // Row 2
  [
    KeyDef(label: 'A', value: 'a', swipeDownValue: '\x01'), // Ctrl+A
    KeyDef(label: 'S', value: 's', swipeDownValue: '\x13'), // Ctrl+S
    KeyDef(label: 'D', value: 'd', swipeDownValue: '\x04'), // Ctrl+D
    KeyDef(label: 'F', value: 'f', swipeDownValue: '\x06'), // Ctrl+F
    KeyDef(label: 'G', value: 'g', swipeDownValue: '\x07'), // Ctrl+G
    KeyDef(label: 'H', value: 'h', swipeDownValue: '\x08'), // Ctrl+H (Backspace)
    KeyDef(label: 'J', value: 'j', swipeDownValue: '\x0A'), // Ctrl+J
    KeyDef(label: 'K', value: 'k', swipeDownValue: '\x0B'), // Ctrl+K
    KeyDef(label: 'L', value: 'l', swipeDownValue: '\x0C'), // Ctrl+L
  ],
  // Row 3
  [
    KeyDef(label: 'Z', value: 'z', swipeDownValue: '\x1A'), // Ctrl+Z
    KeyDef(label: 'X', value: 'x', swipeDownValue: '\x18'), // Ctrl+X
    KeyDef(label: 'C', value: 'c', swipeDownValue: '\x03'), // Ctrl+C
    KeyDef(label: 'V', value: 'v', swipeDownValue: '\x16'), // Ctrl+V
    KeyDef(label: 'B', value: 'b', swipeDownValue: '\x02'), // Ctrl+B
    KeyDef(label: 'N', value: 'n', swipeDownValue: '\x0E'), // Ctrl+N
    KeyDef(label: 'M', value: 'm', swipeDownValue: '\x0D'), // Ctrl+M
    KeyDef(label: 'BS', value: '\x7F', flex: 1.5),     // Backspace
  ],
  // Row 4
  [
    KeyDef(label: 'Space', value: ' ', flex: 4.0),
    KeyDef(label: 'Enter', value: '\r', flex: 2.0),
  ],
];

// Layer 1: Numerics and Core Symbols
const List<List<KeyDef>> kLayer1 = [
  // Row 1: Numbers
  [
    KeyDef(label: '1', value: '1', swipeUpValue: '!'),
    KeyDef(label: '2', value: '2', swipeUpValue: '@'),
    KeyDef(label: '3', value: '3', swipeUpValue: '#'),
    KeyDef(label: '4', value: '4', swipeUpValue: '\$'),
    KeyDef(label: '5', value: '5', swipeUpValue: '%'),
    KeyDef(label: '6', value: '6', swipeUpValue: '^'),
    KeyDef(label: '7', value: '7', swipeUpValue: '&'),
    KeyDef(label: '8', value: '8', swipeUpValue: '*'),
    KeyDef(label: '9', value: '9', swipeUpValue: '('),
    KeyDef(label: '0', value: '0', swipeUpValue: ')'),
  ],
  // Row 2: Structural programming chars
  [
    KeyDef(label: '{', value: '{'),
    KeyDef(label: '}', value: '}'),
    KeyDef(label: '[', value: '['),
    KeyDef(label: ']', value: ']'),
    KeyDef(label: '(', value: '('),
    KeyDef(label: ')', value: ')'),
    KeyDef(label: '<', value: '<'),
    KeyDef(label: '>', value: '>'),
  ],
  // Row 3: Math and comparison operators
  [
    KeyDef(label: '+', value: '+'),
    KeyDef(label: '-', value: '-'),
    KeyDef(label: '=', value: '='),
    KeyDef(label: '/', value: '/'),
    KeyDef(label: '*', value: '*'),
    KeyDef(label: '%', value: '%'),
    KeyDef(label: '_', value: '_'),
    KeyDef(label: 'BS', value: '\x7F', flex: 1.5),
  ],
  // Row 4
  [
    KeyDef(label: 'Space', value: ' ', flex: 4.0),
    KeyDef(label: 'Enter', value: '\r', flex: 2.0),
  ],
];

// Layer 2: Extended Symbols and Function Keys
const List<List<KeyDef>> kLayer2 = [
  // Row 1: Terminal special chars
  [
    KeyDef(label: '|', value: '|'),
    KeyDef(label: '\\', value: '\\'),
    KeyDef(label: '~', value: '~'),
    KeyDef(label: '`', value: '`'),
    KeyDef(label: '&', value: '&'),
    KeyDef(label: '#', value: '#'),
    KeyDef(label: ';', value: ';'),
    KeyDef(label: ':', value: ':'),
    KeyDef(label: '\'', value: '\''),
    KeyDef(label: '"', value: '"'),
  ],
  // Row 2: More symbols
  [
    KeyDef(label: '!', value: '!'),
    KeyDef(label: '@', value: '@'),
    KeyDef(label: '\$', value: '\$'),
    KeyDef(label: '^', value: '^'),
    KeyDef(label: '.', value: '.'),
    KeyDef(label: ',', value: ','),
    KeyDef(label: '?', value: '?'),
    KeyDef(label: 'BS', value: '\x7F', flex: 1.5),
  ],
  // Row 3: Function keys F1-F6
  [
    KeyDef(label: 'F1', value: '\x1bOP'),
    KeyDef(label: 'F2', value: '\x1bOQ'),
    KeyDef(label: 'F3', value: '\x1bOR'),
    KeyDef(label: 'F4', value: '\x1bOS'),
    KeyDef(label: 'F5', value: '\x1b[15~'),
    KeyDef(label: 'F6', value: '\x1b[17~'),
  ],
  // Row 4: Function keys F7-F12
  [
    KeyDef(label: 'F7', value: '\x1b[18~'),
    KeyDef(label: 'F8', value: '\x1b[19~'),
    KeyDef(label: 'F9', value: '\x1b[20~'),
    KeyDef(label: 'F10', value: '\x1b[21~'),
    KeyDef(label: 'F11', value: '\x1b[23~'),
    KeyDef(label: 'F12', value: '\x1b[24~'),
  ],
];

const kAllLayers = [kLayer0, kLayer1, kLayer2];
const kLayerNames = ['ABC', '123', 'SYM'];
