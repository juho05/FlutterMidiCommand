// Vendored from the `midi` package (https://github.com/maks/dart_midi),
// so the Linux/ALSA implementation can be maintained alongside this plugin.

import 'dart:typed_data';

import 'alsa_midi_device.dart';

class MidiMessage {
  int timestamp;
  Uint8List data;
  AlsaMidiDevice device;

  MidiMessage(this.data, this.timestamp, this.device);

  Map<String, Object> get toDictionary {
    return {
      'data': data,
      'timestamp': timestamp,
      'sender': device.toDictionary
    };
  }

  @override
  String toString() {
    return toDictionary.toString();
  }
}