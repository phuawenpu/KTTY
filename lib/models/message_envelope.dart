import 'dart:convert';

class MessageEnvelope {
  final int? seq;
  final String type;
  final String payload;

  MessageEnvelope({
    this.seq,
    required this.type,
    required this.payload,
  });

  factory MessageEnvelope.fromJson(Map<String, dynamic> json) {
    return MessageEnvelope(
      seq: json['seq'] as int?,
      type: json['type'] as String,
      payload: json['payload'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'type': type,
      'payload': payload,
    };
    if (seq != null) map['seq'] = seq;
    return map;
  }

  String encode() => jsonEncode(toJson());

  static MessageEnvelope decode(String data) {
    return MessageEnvelope.fromJson(jsonDecode(data) as Map<String, dynamic>);
  }
}
