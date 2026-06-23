import 'midi_port.dart';

class MidiDevice {
  String name;
  String id;
  String type;
  List<MidiPort> inputPorts = [];
  List<MidiPort> outputPorts = [];
  bool connected;

  MidiDevice(this.id, this.name, this.type, this.connected);

  Map<String, Object> get toDictionary {
    return {
      "name": name,
      "id": id,
      "type": type,
      // Use the same string representation as the native getDevices payload and
      // the receive-side parsing (`connected == "true"`), rather than a bool.
      "connected": connected ? "true" : "false",
    };
  }
}
