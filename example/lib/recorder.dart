
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';

class MidiRecorder {

  factory MidiRecorder() {
    _instance ??= MidiRecorder._();
    return _instance!;
  }

  static MidiRecorder? _instance;

  MidiRecorder._();

  bool _recording = false;

  bool get recording => _recording;

  final List<MidiPacket> _messages = [];

  StreamSubscription<MidiPacket>? _midiSub;

  startRecording() {
    _recording = true;
    _midiSub = MidiCommand().onMidiDataReceived?.listen((packet) {
      _messages.add(packet);
    });
  }

  stopRecording() {
    _recording = false;
    _midiSub?.cancel();
  }


  exportRecording() async {
    var rows = _messages.map((e) => [e.timestamp, ...e.data.map((e) => e.toString())]).toList();

    var csv = const ListToCsvConverter().convert(rows);

    // file_picker 12.x writes the provided bytes to the chosen path itself, so
    // we pass the CSV content as bytes and no longer write the file manually.
    String? outputFile = await FilePicker.saveFile(
      dialogTitle: 'Please select an output file:',
      fileName: 'midi_recording.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
      bytes: Uint8List.fromList(utf8.encode(csv)),
    );

    if (outputFile == null) {
      // User canceled the picker
    }

    print("recording exported");
  }

  clearRecording() {
    _messages.clear();
  }
}

