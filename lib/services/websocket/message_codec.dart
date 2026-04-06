import 'dart:convert';
import '../../models/message_envelope.dart';

class MessageCodec {
  static String encodeEnvelope(MessageEnvelope envelope) {
    return envelope.encode();
  }

  static MessageEnvelope decodeEnvelope(String data) {
    return MessageEnvelope.decode(data);
  }

  static String encodeJoinMessage(String roomId) {
    return jsonEncode({'action': 'join', 'room_id': roomId});
  }

  static String base64Encode(List<int> bytes) {
    return base64.encode(bytes);
  }

  static List<int> base64Decode(String encoded) {
    return base64.decode(encoded);
  }
}
