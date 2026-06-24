import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'flutter_midi_command_windows.dart';
import 'midi_command_platform_interface.dart';


const _numberOfBuffers = 4;

class WindowsMidiDevice extends MidiDevice {
  Map<int, MIDIINCAPS> _ins = {};
  Map<int, MIDIOUTCAPS> _outs = {};

  StreamController<MidiPacket> _rxStreamCtrl;
  StreamController<String> _setupStreamController;

  final hMidiInDevicePtr = malloc<Pointer>();
  final hMidiOutDevicePtr = malloc<Pointer>();

  HMIDIIN get _hMidiIn => HMIDIIN(hMidiInDevicePtr.value);
  HMIDIOUT get _hMidiOut => HMIDIOUT(hMidiOutDevicePtr.value);

  int callbackAddress;

  final _bufferSize = 8192;

  List<Pointer<MIDIHDR>> _midiInHeaders = List.generate(_numberOfBuffers, (index) => nullptr);
  List<Pointer<BYTE>> _midiInBuffers = List.generate(_numberOfBuffers, (index) => nullptr);

  Pointer<MIDIHDR> _midiOutHeader = nullptr;
  Pointer<BYTE> _midiOutBuffer = nullptr;

  WindowsMidiDevice(String id, String name, this._rxStreamCtrl,
      this._setupStreamController, this.callbackAddress)
      : super(id, name, 'native', false);

  /// Connect to the device, ie. open input and output ports
  /// NOTE: Currently only the first input/output port is considered
  bool connect() {
    // Open input

    var mIn = _ins.entries.firstOrNull;
    if (mIn != null) {
      var id = mIn.key;
      int result = midiInOpen(
          hMidiInDevicePtr, id, callbackAddress, 0, CALLBACK_FUNCTION);
      if (result != 0) {
        print("OPEN ERROR($result): ${midiErrorMessage(result)}");
        return false;
      } else {
        // Setup buffer
        for (int i = 0; i < _numberOfBuffers; i++) {
          _midiInBuffers[i] = malloc<BYTE>(_bufferSize);
          _midiInHeaders[i] = malloc<MIDIHDR>();
          _midiInHeaders[i].ref.lpData = PSTR(_midiInBuffers[i].cast());
          _midiInHeaders[i].ref.dwBufferLength = _bufferSize;
          _midiInHeaders[i].ref.dwFlags = 0;
          _midiInHeaders[i].ref.dwBytesRecorded = 0;

          result = midiInPrepareHeader(
              _hMidiIn, _midiInHeaders[i], sizeOf<MIDIHDR>());
          if (result != 0) {
            print("HDR PREP ERROR: ${midiErrorMessage(result)}");
            return false;
          }

          result = midiInAddBuffer(
              _hMidiIn, _midiInHeaders[i], sizeOf<MIDIHDR>());
          if (result != 0) {
            print("HDR ADD ERROR: ${midiErrorMessage(result)}");
            return false;
          }
        }

        result = midiInStart(_hMidiIn);
        if (result != 0) {
          print("START ERROR: ${midiErrorMessage(result)}");
          return false;
        }
      }
    }

    // Open output
    var mOut = _outs.entries.firstOrNull;
    if (mOut != null) {
      var id = mOut.key;

      int result = midiOutOpen(hMidiOutDevicePtr, id, 0, 0, CALLBACK_NULL);
      if (result != 0) {
        print("OUT OPEN ERROR: result");
        return false;
      }

      _midiOutBuffer = malloc<BYTE>(_bufferSize);
      _midiOutHeader = malloc<MIDIHDR>();
    }
    connected = true;
    _setupStreamController.add("deviceConnected");
    return true;
  }

  bool disconnect() {
    int result;
    if (_ins.length > 0) {
      result = midiInReset(_hMidiIn);
      if (result != 0) {
        print("RESET ERROR($result): ${midiErrorMessage(result)}");
      }

      for (int i=0; i < _numberOfBuffers; i++) {
        if (_midiInHeaders[i] != nullptr) {
          midiInUnprepareHeader(
              _hMidiIn, _midiInHeaders[i], sizeOf<MIDIHDR>());
          free(_midiInHeaders[i]);
        }
        if (_midiInBuffers[i] != nullptr) {
          free(_midiInBuffers[i]);
        }
      }

      result = midiInStop(_hMidiIn);
      if (result != 0) {
        print("STOP ERROR($result): ${midiErrorMessage(result)}");
      }

      result = midiInClose(_hMidiIn);
      if (result != 0) {
        print("CLOSE ERROR($result): ${midiErrorMessage(result)}");
      }

      free(hMidiInDevicePtr);
    }

    if (_outs.length > 0) {
      result = midiOutClose(_hMidiOut);
      if (result != 0) {
        print("OUT CLOSE ERROR($result): ${midiErrorMessage(result)}");
      }
      free(hMidiOutDevicePtr);
    }

    free(_midiOutBuffer);
    free(_midiOutHeader);

    connected = false;
    return true;
  }

  addInput(int id, MIDIINCAPS input) {
    _ins[id] = input;
    inputPorts.add(MidiPort(input.wPid, MidiPortType.IN));
  }

  addOutput(int id, MIDIOUTCAPS output) {
    _outs[id] = output;
    outputPorts.add(MidiPort(output.wPid, MidiPortType.OUT));
  }

  // The callback delivers the input handle as a raw address (see _onMidiData),
  // so compare against the handle pointer's address rather than the pointer.
  containsMidiIn(int input) => hMidiInDevicePtr.value.address == input;

  _resetHeader(Pointer<MIDIHDR> midiHdrPointer) {
    midiInAddBuffer(_hMidiIn, midiHdrPointer, sizeOf<MIDIHDR>());
  }

  handleData(Uint8List data, int timestamp) {
    // print('handle data $data');
    _rxStreamCtrl.add(MidiPacket(data, timestamp, this));
  }

  /// Accumulates SysEx that may be delivered split across several
  /// MM_MIM_LONGDATA callbacks. The buffer is per-device, so concurrent SysEx
  /// streams from other devices can no longer corrupt each other.
  final List<int> _partialSysExBuffer = [];

  handleSysexData(Uint8List data, Pointer<MIDIHDR> midiHdrPointer) {
    // print('handle SysEX: $data');
    // A new SysEx (starting with 0xF0) resets any half-received buffer.
    if (data.isNotEmpty && data.first == 0xF0) {
      _partialSysExBuffer.clear();
    }
    // Copy out of the native buffer (addAll copies the bytes) before it is
    // handed back to the driver via _resetHeader below.
    _partialSysExBuffer.addAll(data);

    if (_partialSysExBuffer.isNotEmpty && _partialSysExBuffer.last == 0xF7) {
      // Emit the full reassembled message, not just the final chunk.
      _rxStreamCtrl
          .add(MidiPacket(Uint8List.fromList(_partialSysExBuffer), 0, this));
      _partialSysExBuffer.clear();
    }

    // Return the buffer to the driver so it can keep receiving, including for
    // intermediate chunks of a multi-part SysEx.
    _resetHeader(midiHdrPointer);
  }

  send(Uint8List data) async {
    // Set data in out buffer
    _midiOutBuffer.asTypedList(data.length).setAll(0, data);
    _midiOutHeader.ref.lpData = PSTR(_midiOutBuffer.cast());
    _midiOutHeader.ref.dwBytesRecorded =
        _midiOutHeader.ref.dwBufferLength = data.length;
    _midiOutHeader.ref.dwFlags = 0;

    int result = midiOutPrepareHeader(
        _hMidiOut, _midiOutHeader, sizeOf<MIDIHDR>());
    if (result != 0) {
      print("HDR OUT PREP ERROR: ${midiErrorMessage(result)}");
    }

    result = midiOutLongMsg(
        _hMidiOut, _midiOutHeader, sizeOf<MIDIHDR>());
    if (result != 0) {
      print("SEND ERROR($result): ${midiErrorMessage(result)}");
    }

    result = midiOutUnprepareHeader(
        _hMidiOut, _midiOutHeader, sizeOf<MIDIHDR>());
    if (result != 0) {
      print("OUT UNPREPARE ERROR($result): ${midiErrorMessage(result)}");
    }
  }
}
