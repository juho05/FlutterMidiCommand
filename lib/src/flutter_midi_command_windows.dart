import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:win32/win32.dart';
import 'package:device_manager/device_event.dart';
import 'package:device_manager/device_manager.dart';

import 'ble_midi_device.dart';
import 'midi_command_platform_interface.dart';
import 'windows_midi_device.dart';

class FlutterMidiCommandWindows extends MidiCommandPlatform {
  StreamController<MidiPacket> _rxStreamController =
      StreamController<MidiPacket>.broadcast();
  late Stream<MidiPacket> _rxStream;
  StreamController<String> _setupStreamController =
      StreamController<String>.broadcast();
  late Stream<String> _setupStream;

  StreamController<String> _bluetoothStateStreamController =
      StreamController<String>.broadcast();
  late Stream<String> _bluetoothStateStream;

  StreamController<MidiDevice> _deviceDisconnectedController =
      StreamController<MidiDevice>.broadcast();
  late Stream<MidiDevice> _deviceDisconnectedStream;

  Map<String, WindowsMidiDevice> _connectedDevices =
      Map<String, WindowsMidiDevice>();

  // BLE Vars

  String _bleState = "unknown";
  Map<String, BLEMidiDevice> _discoveredBLEDevices = {};

  factory FlutterMidiCommandWindows() {
    if (_instance == null) {
      _instance = FlutterMidiCommandWindows._();
    }
    return _instance!;
  }

  static FlutterMidiCommandWindows? _instance;

  FlutterMidiCommandWindows._() {
    _setupStream = _setupStreamController.stream;
    _rxStream = _rxStreamController.stream;
    _bluetoothStateStream = _bluetoothStateStreamController.stream;
    _deviceDisconnectedStream = _deviceDisconnectedController.stream;

    _setupDeviceManager();
  }

  _setupDeviceManager() async {
    await Future.delayed(Duration(seconds: 3));
    DeviceManager().addListener(() {
      var event = DeviceManager().lastEvent;
      if (event != null) {
        if (event.eventType == EventType.add) {
          _setupStreamController.add("deviceAppeared");
        } else if (event.eventType == EventType.remove) {
          _setupStreamController.add("deviceDisappeared");
          _handleNativeDeviceRemoval();
        }
      }
    });
  }

  /// The windows implementation of [MidiCommandPlatform]
  ///
  /// This class implements the `package:flutter_midi_command_platform_interface` functionality for windows
  static void registerWith() {
    MidiCommandPlatform.instance = FlutterMidiCommandWindows();
  }

  //#region
  @override
  Future<List<MidiDevice>> get devices async {
    var devices = Map<String, MidiDevice>();

    Pointer<MIDIINCAPS> inCaps = malloc<MIDIINCAPS>();
    int nMidiDeviceNum = midiInGetNumDevs();

    Map<String, int> deviceInputs = {};

    for (int i = 0; i < nMidiDeviceNum; ++i) {
      midiInGetDevCaps(i, inCaps, sizeOf<MIDIINCAPS>());
      var name = inCaps.ref.szPname;
      var id = name;

      if (!deviceInputs.containsKey(name)) {
        deviceInputs[name] = 0;
      } else {
        deviceInputs[name] = deviceInputs[name]! + 1;
      }

      if (deviceInputs[name]! > 0) {
        id = id + " (${deviceInputs[name]})";
      }

      //print(
      //    "${id} ${inCaps.ref.wMid} ${inCaps.ref.wPid} ${inCaps.ref.hashCode} ${inCaps.ref.dwSupport}");

      bool isConnected = _connectedDevices.containsKey(id);
      //print('found IN at i $i id $id for device $name');
      devices[id] = WindowsMidiDevice(id, name, _rxStreamController,
          _setupStreamController, _midiCB.nativeFunction.address)
        ..addInput(i, inCaps.ref)
        ..connected = isConnected;
    }

    free(inCaps);

    Pointer<MIDIOUTCAPS> outCaps = malloc<MIDIOUTCAPS>();
    nMidiDeviceNum = midiOutGetNumDevs();

    Map<String, int> deviceOutputs = {};

    for (int i = 0; i < nMidiDeviceNum; ++i) {
      midiOutGetDevCaps(i, outCaps, sizeOf<MIDIOUTCAPS>());
      var name = outCaps.ref.szPname;
      var id = name;

      if (!deviceOutputs.containsKey(name)) {
        deviceOutputs[name] = 0;
      } else {
        deviceOutputs[name] = deviceOutputs[name]! + 1;
      }

      if (deviceOutputs[name]! > 0) {
        id = id + " (${deviceOutputs[name]})";
      }

      if (devices.containsKey(id)) {
        // print('add OUT at i $i id $id for device $name}');

        // Add to existing device
        devices[id]! as WindowsMidiDevice..addOutput(i, outCaps.ref);
      } else {
        // print('found OUT at i $i id $id for device $name');

        bool isConnected = _connectedDevices.containsKey(id);
        devices[id] = WindowsMidiDevice(id, name, _rxStreamController,
            _setupStreamController, _midiCB.nativeFunction.address)
          ..addOutput(i, outCaps.ref)
          ..connected = isConnected;
      }
    }

    free(outCaps);

    devices.addAll(_discoveredBLEDevices);

    return devices.values.toList();
  }

  /// Prepares Bluetooth system
  @override
  Future<void> startBluetoothCentral() async {
    UniversalBle.timeout = const Duration(seconds: 10);

    UniversalBle.onAvailabilityChange = (state) {
      _bleState = state.name;
      _bluetoothStateStreamController.add(state.name);
    };

    UniversalBle.onScanResult = (result) {
      if (!_discoveredBLEDevices.containsKey(result.deviceId)) {
        if (result.name != null) {
          debugPrint(
              "${result.name} ${result.deviceId} ${result.manufacturerDataList.map((e) => e.toString()).join(', ')}");
          _discoveredBLEDevices[result.deviceId] =
              BLEMidiDevice(result.deviceId, result.name!, _rxStreamController);
          _setupStreamController.add('deviceAppeared');
        }
      }
    };

    UniversalBle.onConnectionChange = (deviceId, isConnected, error) {
      if (_discoveredBLEDevices.containsKey(deviceId)) {
        if (isConnected) {
          _discoveredBLEDevices[deviceId]!.connectionState =
              BleConnectionState.connected;
          _setupStreamController.add('deviceConnected');
        } else {
          // Only treat this as a disconnect if we were actually connected, so we
          // don't emit for a discovered-but-never-connected device that drops.
          // Keep the device in the discovered list so it stays reconnectable
          // without requiring a new scan.
          var device = _discoveredBLEDevices[deviceId];
          if (device != null && device.connected) {
            device.connected = false;
            _setupStreamController.add('deviceDisconnected');
            _deviceDisconnectedController.add(device);
          }
        }
      }
    };

    UniversalBle.onValueChange = (deviceId, characteristicId, Uint8List data) {
      if (_discoveredBLEDevices.containsKey(deviceId)) {
        _discoveredBLEDevices[deviceId]!.handleData(data);
      }
    };

    UniversalBle.onPairingStateChange = (deviceId, isPaired) {
      if (_discoveredBLEDevices.containsKey(deviceId)) {
        _discoveredBLEDevices[deviceId]!.pairingState = isPaired;
      }
    };
  }

  /// Stream firing events whenever a change in bluetooth central state happens
  @override
  Stream<String>? get onBluetoothStateChanged {
    return _bluetoothStateStream;
  }

  /// Returns the current state of the bluetooth subsystem
  @override
  Future<String> bluetoothState() async {
    return _bleState;
  }

  /// Starts scanning for BLE MIDI devices.
  ///
  /// Found devices will be included in the list returned by [devices].
  Future<void> startScanningForBluetoothDevices() async {
    try {
      await UniversalBle.startScan(
          scanFilter: ScanFilter(withServices: [MIDI_SERVICE_ID]));
    } catch (e) {
      print(e.toString());
    }
  }

  @override
  void stopScanningForBluetoothDevices() {
    /// Stops scanning for BLE MIDI devices.
    UniversalBle.stopScan();

    // Prune discovered-but-not-connected devices so a later [devices] call no
    // longer lists BLE peripherals that went out of range while scanning (BLE
    // provides no "scan result removed" event, so this is the point at which we
    // know the discovered set is stale). Connected devices are kept since the
    // active session - data reception and disconnect - relies on their entry
    // here. Mirrors the Android backend, which prunes the discovered set on
    // scan stop (it can clear the whole set because it tracks connected devices
    // separately; here connected devices live in the same map).
    _discoveredBLEDevices.removeWhere((_, device) => !device.connected);
  }

  /// Connects to the device.
  @override
  Future<void> connectToDevice(MidiDevice device,
      {List<MidiPort>? ports}) async {
    if (device is WindowsMidiDevice) {
      var success = device.connect();
      if (success) {
        _connectedDevices[device.id] = device;
      } else {
        print("failed to connect $device");
      }
    } else if (device is BLEMidiDevice) {
      device.connect();
    }
  }

  /// Disconnects from the device.
  @override
  void disconnectDevice(MidiDevice device, {bool remove = true}) {
    if (device is WindowsMidiDevice) {
      if (_connectedDevices.containsKey(device.id)) {
        var windowsDevice = _connectedDevices[device.id]!;
        var result = windowsDevice.disconnect();
        if (result) {
          // For an explicit disconnect remove the device from the connected map
          // and notify. When called from teardown (remove: false) the map is
          // being iterated and cleared by the caller, so skip the mutation here
          // to avoid a ConcurrentModificationError.
          if (remove) {
            _connectedDevices.remove(device.id);
            _setupStreamController.add("deviceDisconnected");
            _deviceDisconnectedController.add(windowsDevice);
          }
        } else {
          print("failed to close $windowsDevice");
        }
      }
    } else if (device is BLEMidiDevice) {
      // The disconnect event is emitted from the onConnectionChange callback.
      device.disconnect();
    }
  }

  @override
  void teardown() {
    // Close callback isolate
    _midiCB.close();

    // Disconnect native devices. Pass remove: false so disconnectDevice does not
    // mutate _connectedDevices while we iterate it; the map is cleared afterwards
    // and the disconnect event is emitted here per device.
    _connectedDevices.values.forEach((device) {
      disconnectDevice(device, remove: false);
      device.connected = false;
      _deviceDisconnectedController.add(device);
    });
    _connectedDevices.clear();

    // Disconnect any connected BLE devices as well. Their disconnect event is
    // emitted from the onConnectionChange callback.
    _discoveredBLEDevices.values
        .where((device) => device.connected)
        .forEach((device) {
      disconnectDevice(device, remove: false);
    });

    _setupStreamController.add("deviceDisconnected");
    _rxStreamController.close();
  }

  /// Sends data to the currently connected devices or a specific midi device
  ///
  /// Data is an UInt8List of individual MIDI command bytes.
  @override
  void sendData(Uint8List data, {int? timestamp, String? deviceId}) {
    if (deviceId != null) {
      // Send to specific device, if present
      _connectedDevices[deviceId]?.send(data);

      _discoveredBLEDevices.values
          .where((element) => element.deviceId == deviceId)
          .forEach((element) {
        element.send(data);
      });
    } else {
      // Send to all devices
      _connectedDevices.values.forEach((device) {
        device.send(data);
      });

      _discoveredBLEDevices.values
          .where((element) => element.connected)
          .forEach((element) {
        element.send(data);
      });
    }
  }

  /// Stream firing events whenever a midi package is received.
  ///
  /// The event contains the raw bytes contained in the MIDI package.
  @override
  Stream<MidiPacket>? get onMidiDataReceived {
    //print('MIDI DATA RECEIVED ');
    return _rxStream;
  }

  /// Stream firing events whenever a change in the MIDI setup occurs.
  ///
  /// For example, when a new BLE devices is discovered.
  @override
  Stream<String>? get onMidiSetupChanged {
    return _setupStream;
  }

  /// Stream firing whenever a connected device disconnects (explicitly or unexpectedly).
  @override
  Stream<MidiDevice>? get onMidiDeviceDisconnected {
    return _deviceDisconnectedStream;
  }

  /// Creates a virtual MIDI source
  ///
  /// The virtual MIDI source appears as a virtual port in other apps.
  /// Currently only supported on iOS.
  @override
  void addVirtualDevice({String? name}) {
    // Not implemented
    print('addVirtualDevice Not implemented on Windows');
  }

  /// Removes a previously addd virtual MIDI source.
  @override
  void removeVirtualDevice({String? name}) {
    // Not implemented
    print('removeVirtualDevice Not implemented on Windows');
  }

  @override
  Future<bool?> get isNetworkSessionEnabled async {
    return false;
  }

  @override
  void setNetworkSessionEnabled(bool enabled) {
    // Not implemented
    print('setNetworkSessionEnabled Not implemented on Windows');
  }

  WindowsMidiDevice? findMidiDeviceForSource(int src) {
    for (WindowsMidiDevice wmd in _connectedDevices.values) {
      if (wmd.containsMidiIn(src)) {
        return wmd;
      }
    }
    return null;
  }

  /// Enumerates the ids of currently present native MIDI devices, using the same
  /// id/dedup scheme as [devices].
  Set<String> _presentNativeDeviceIds() {
    var ids = <String>{};

    Pointer<MIDIINCAPS> inCaps = malloc<MIDIINCAPS>();
    int nIn = midiInGetNumDevs();
    Map<String, int> deviceInputs = {};
    for (int i = 0; i < nIn; ++i) {
      midiInGetDevCaps(i, inCaps, sizeOf<MIDIINCAPS>());
      var name = inCaps.ref.szPname;
      var id = name;
      if (!deviceInputs.containsKey(name)) {
        deviceInputs[name] = 0;
      } else {
        deviceInputs[name] = deviceInputs[name]! + 1;
      }
      if (deviceInputs[name]! > 0) {
        id = id + " (${deviceInputs[name]})";
      }
      ids.add(id);
    }
    free(inCaps);

    Pointer<MIDIOUTCAPS> outCaps = malloc<MIDIOUTCAPS>();
    int nOut = midiOutGetNumDevs();
    Map<String, int> deviceOutputs = {};
    for (int i = 0; i < nOut; ++i) {
      midiOutGetDevCaps(i, outCaps, sizeOf<MIDIOUTCAPS>());
      var name = outCaps.ref.szPname;
      var id = name;
      if (!deviceOutputs.containsKey(name)) {
        deviceOutputs[name] = 0;
      } else {
        deviceOutputs[name] = deviceOutputs[name]! + 1;
      }
      if (deviceOutputs[name]! > 0) {
        id = id + " (${deviceOutputs[name]})";
      }
      ids.add(id);
    }
    free(outCaps);

    return ids;
  }

  /// Detects connected native devices that have been physically removed (e.g. USB
  /// unplug) by diffing against the currently present devices, and notifies clients.
  void _handleNativeDeviceRemoval() {
    var presentIds = _presentNativeDeviceIds();
    var removed = _connectedDevices.keys
        .where((id) => !presentIds.contains(id))
        .toList();
    for (var id in removed) {
      var device = _connectedDevices.remove(id);
      if (device != null) {
        device.disconnect();
        device.connected = false;
        _deviceDisconnectedController.add(device);
        _setupStreamController.add("deviceDisconnected");
      }
    }
  }
  //#endregion
}

String midiErrorMessage(int status) {
  switch (status) {
    case MMSYSERR_ALLOCATED:
      return "Resource already allocated";
    case MMSYSERR_BADDEVICEID:
      return "Device ID out of range";
    case MMSYSERR_INVALFLAG:
      return "Invalid dwFlags";
    case MMSYSERR_INVALPARAM:
      return 'Invalid pointer or structure';
    case MMSYSERR_NOMEM:
      return "Unable to allocate memory";
    case MMSYSERR_INVALHANDLE:
      return "Invalid handle";
    default:
      return "Status $status";
  }
}

NativeCallable<Void Function(IntPtr, Uint32, IntPtr, IntPtr, IntPtr)> _midiCB =
    NativeCallable<MIDIINPROC>.listener(_onMidiData);

const int MHDR_DONE = 0x00000001;
const int MHDR_PREPARED = 0x00000002;
const int MHDR_INQUEUE = 0x00000004;

final List<int> partialSysExBuffer = [];

void _onMidiData(
    int hMidiIn, int wMsg, int dwInstance, int dwParam1, int dwParam2) {
  var dev = FlutterMidiCommandWindows().findMidiDeviceForSource(hMidiIn);
  final midiHdrPointer = Pointer<MIDIHDR>.fromAddress(dwParam1);
  final midiHdr = midiHdrPointer.ref;

  switch (wMsg) {
    case MM_MIM_OPEN:
      dev?.connected = true;
      break;
    case MM_MIM_CLOSE:
      dev?.connected = false;
      break;
    case MM_MIM_DATA:
      // print("data! $dwParam1 at: $dwParam2");
      var data = Uint32List.fromList([dwParam1]).buffer.asUint8List();
      dev?.handleData(data, dwParam2);
      break;
    case MM_MIM_LONGDATA:
      if ((midiHdr.dwFlags & MHDR_DONE) != 0) {
        final dataPointer = midiHdr.lpData.cast<Uint8>();
        final messageData = dataPointer.asTypedList(midiHdr.dwBytesRecorded);

        if (messageData.isNotEmpty && messageData.first == 0xF0) {
          partialSysExBuffer.clear();
        }

        partialSysExBuffer.addAll(messageData);

        if (partialSysExBuffer.isNotEmpty && partialSysExBuffer.last == 0xF7) {
          dev?.handleSysexData(messageData, midiHdrPointer);
          partialSysExBuffer.clear();
        }

        //var pMidiHdr = Pointer.fromAddress(dwParam1).cast<MIDIHDR>();

        //var data = pMidiHdr.ref.lpData
        //    .cast<Uint8>()
        //    .asTypedList(pMidiHdr.ref.dwBytesRecorded);
      } else {
        // Decode and log each flag for debugging
        if ((midiHdr.dwFlags & MHDR_PREPARED) != 0) {
          print('MHDR_PREPARED is set');
        }
        if ((midiHdr.dwFlags & MHDR_INQUEUE) != 0) {
          print('MHDR_INQUEUE is set');
        }
      }

      break;
    case MM_MIM_MOREDATA:
      print("More data - unhandled!");
      break;
    case MM_MIM_ERROR:
      print("Error");
      break;
    case MM_MIM_LONGERROR:
      print("Long error");
      break;
  }
}
