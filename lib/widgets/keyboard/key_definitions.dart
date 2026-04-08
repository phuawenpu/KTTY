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

// Layer 0: QWERTY + common programming symbols
const List<List<KeyDef>> kLayer0 = [
  // Row 1: top symbols row (most used by programmers)
  [
    KeyDef(label: '-', value: '-'),
    KeyDef(label: '_', value: '_'),
    KeyDef(label: '=', value: '='),
    KeyDef(label: '/', value: '/'),
    KeyDef(label: ':', value: ':'),
    KeyDef(label: ';', value: ';'),
    KeyDef(label: '\'', value: '\''),
    KeyDef(label: '"', value: '"'),
    KeyDef(label: '.', value: '.'),
    KeyDef(label: ',', value: ','),
  ],
  // Row 2: QWERTY
  [
    KeyDef(label: 'Q', value: 'q', swipeDownValue: '\x11'),
    KeyDef(label: 'W', value: 'w', swipeDownValue: '\x17'),
    KeyDef(label: 'E', value: 'e', swipeDownValue: '\x05'),
    KeyDef(label: 'R', value: 'r', swipeDownValue: '\x12'),
    KeyDef(label: 'T', value: 't', swipeDownValue: '\x14'),
    KeyDef(label: 'Y', value: 'y', swipeDownValue: '\x19'),
    KeyDef(label: 'U', value: 'u', swipeDownValue: '\x15'),
    KeyDef(label: 'I', value: 'i', swipeDownValue: '\x09'),
    KeyDef(label: 'O', value: 'o', swipeDownValue: '\x0F'),
    KeyDef(label: 'P', value: 'p', swipeDownValue: '\x10'),
  ],
  // Row 3
  [
    KeyDef(label: 'A', value: 'a', swipeDownValue: '\x01'),
    KeyDef(label: 'S', value: 's', swipeDownValue: '\x13'),
    KeyDef(label: 'D', value: 'd', swipeDownValue: '\x04'),
    KeyDef(label: 'F', value: 'f', swipeDownValue: '\x06'),
    KeyDef(label: 'G', value: 'g', swipeDownValue: '\x07'),
    KeyDef(label: 'H', value: 'h', swipeDownValue: '\x08'),
    KeyDef(label: 'J', value: 'j', swipeDownValue: '\x0A'),
    KeyDef(label: 'K', value: 'k', swipeDownValue: '\x0B'),
    KeyDef(label: 'L', value: 'l', swipeDownValue: '\x0C'),
  ],
  // Row 4
  [
    KeyDef(label: 'Z', value: 'z', swipeDownValue: '\x1A'),
    KeyDef(label: 'X', value: 'x', swipeDownValue: '\x18'),
    KeyDef(label: 'C', value: 'c', swipeDownValue: '\x03'),
    KeyDef(label: 'V', value: 'v', swipeDownValue: '\x16'),
    KeyDef(label: 'B', value: 'b', swipeDownValue: '\x02'),
    KeyDef(label: 'N', value: 'n', swipeDownValue: '\x0E'),
    KeyDef(label: 'M', value: 'm', swipeDownValue: '\x0D'),
  ],
  // Row 5: Shift + Space + Enter
  [
    KeyDef(label: '\u21E7', value: '\x00SHIFT', flex: 1.0),
    KeyDef(label: 'Space', value: ' ', flex: 4.0),
    KeyDef(label: 'Enter', value: '\r', flex: 2.0),
  ],
];

// Layer 1: Numerics and Brackets
const List<List<KeyDef>> kLayer1 = [
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
  [
    KeyDef(label: '+', value: '+'),
    KeyDef(label: '-', value: '-'),
    KeyDef(label: '=', value: '='),
    KeyDef(label: '/', value: '/'),
    KeyDef(label: '*', value: '*'),
    KeyDef(label: '%', value: '%'),
    KeyDef(label: '_', value: '_'),
    KeyDef(label: '.', value: '.'),
  ],
  [
    KeyDef(label: 'Space', value: ' ', flex: 4.0),
    KeyDef(label: 'Enter', value: '\r', flex: 2.0),
  ],
];

// Layer 2: Extended Symbols and Function Keys
const List<List<KeyDef>> kLayer2 = [
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
  [
    KeyDef(label: '!', value: '!'),
    KeyDef(label: '@', value: '@'),
    KeyDef(label: '\$', value: '\$'),
    KeyDef(label: '^', value: '^'),
    KeyDef(label: ',', value: ','),
    KeyDef(label: '?', value: '?'),
  ],
  [
    KeyDef(label: 'F1', value: '\x1bOP'),
    KeyDef(label: 'F2', value: '\x1bOQ'),
    KeyDef(label: 'F3', value: '\x1bOR'),
    KeyDef(label: 'F4', value: '\x1bOS'),
    KeyDef(label: 'F5', value: '\x1b[15~'),
    KeyDef(label: 'F6', value: '\x1b[17~'),
  ],
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
