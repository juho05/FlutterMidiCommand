import 'dart:typed_data';

import 'midi_device.dart';

class MidiPacket {
  int timestamp;
  Uint8List data;
  MidiDevice device;

  MidiPacket(this.data, this.timestamp, this.device);

  Map<String, Object> get toDictionary {
    return {
      "data": data,
      "timestamp": timestamp,
      "sender": device.toDictionary
    };
  }
}
