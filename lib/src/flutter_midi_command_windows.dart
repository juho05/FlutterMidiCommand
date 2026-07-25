import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:device_manager/device_event.dart';
import 'package:device_manager/device_manager.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

import 'ble_midi_device.dart';
import 'ble_midi_manager.dart';
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

  late final BleMidiManager _bleManager;

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

    _bleManager = BleMidiManager(
      rxStreamController: _rxStreamController,
      onSetupEvent: (event) => _setupStreamController.add(event),
      onDeviceDisconnected: (device) =>
          _deviceDisconnectedController.add(device),
      onBluetoothState: (state) => _bluetoothStateStreamController.add(state),
    );
  }

  bool _deviceManagerReady = false;

  /// Subscribes to native hot-plug events. DeviceManager talks over a method
  /// channel, which cannot be touched from the plugin registrant that
  /// constructs this class - the binding does not exist yet at that point - so
  /// this is hooked up on the first call coming from the app instead. That is
  /// also the earliest moment at which an event could matter to anyone.
  void _ensureDeviceManager() {
    if (_deviceManagerReady) return;
    _deviceManagerReady = true;

    DeviceManager().addListener(() {
      var event = DeviceManager().lastEvent;
      if (event != null) {
        if (event.eventType == EventType.add) {
          _setupStreamController.add("deviceAppeared");
        } else if (event.eventType == EventType.remove) {
          _handleNativeDeviceRemoval();
          _setupStreamController.add("deviceDisappeared");
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
    _ensureDeviceManager();
    // Reconcile BLE first so a device that dropped while nothing was watching is
    // never reported as still connected.
    await _bleManager.reconcile();

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

      //print('found IN at i $i id $id for device $name');
      devices[id] = WindowsMidiDevice(
        id,
        name,
        _rxStreamController,
        _midiCB.nativeFunction.address,
      )..addInput(i, inCaps.ref);
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

        devices[id] = WindowsMidiDevice(
          id,
          name,
          _rxStreamController,
          _midiCB.nativeFunction.address,
        )..addOutput(i, outCaps.ref);
      }
    }

    free(outCaps);

    // Hand out the live object for a connected device rather than the wrapper
    // just built from the enumeration: the stored one owns the open handles, and
    // it is the one rx packets are tagged with.
    _connectedDevices.forEach((id, device) {
      if (devices.containsKey(id)) devices[id] = device;
    });

    devices.addAll(_bleManager.devices);

    return devices.values.toList();
  }

  /// Prepares Bluetooth system
  @override
  Future<void> startBluetoothCentral() async {
    _ensureDeviceManager();
    await _bleManager.start();
  }

  /// Stream firing events whenever a change in bluetooth central state happens
  @override
  Stream<String>? get onBluetoothStateChanged {
    return _bluetoothStateStream;
  }

  /// Returns the current state of the bluetooth subsystem
  @override
  Future<String> bluetoothState() async {
    return _bleManager.state;
  }

  /// Starts scanning for BLE MIDI devices.
  ///
  /// Found devices will be included in the list returned by [devices].
  /// Throws when Bluetooth is not available.
  @override
  Future<void> startScanningForBluetoothDevices() async {
    await _bleManager.startScanning();
  }

  /// Stops scanning for BLE MIDI devices.
  @override
  void stopScanningForBluetoothDevices() {
    _bleManager.stopScanning();
  }

  /// Connects to the device.
  ///
  /// The returned future resolves once the device is usable, and throws a
  /// [PlatformException] if the connection could not be established.
  @override
  Future<void> connectToDevice(
    MidiDevice device, {
    List<MidiPort>? ports,
  }) async {
    _ensureDeviceManager();

    if (device is BLEMidiDevice) {
      return _bleManager.connect(device);
    }

    var windowsDevice = device as WindowsMidiDevice;
    // Keyed by id, not by object: the devices getter builds a fresh wrapper on
    // every call, so without this two enumerations could open two sets of
    // handles for the same device and orphan the first.
    if (_connectedDevices.containsKey(windowsDevice.id)) {
      throw PlatformException(
        code: 'MESSAGEERROR',
        message: 'Device already connected',
        details: windowsDevice.id,
      );
    }

    if (!windowsDevice.connect()) {
      _setupStreamController.add("connectionFailed");
      throw PlatformException(
        code: 'MESSAGEERROR',
        message: 'Failed to open device',
        details: windowsDevice.id,
      );
    }
    _connectedDevices[windowsDevice.id] = windowsDevice;
    _setupStreamController.add("deviceConnected");
  }

  /// Disconnects from the device.
  @override
  void disconnectDevice(MidiDevice device) {
    if (device is BLEMidiDevice) {
      _bleManager.disconnect(device);
      return;
    }
    _removeNativeDevice(device.id);
  }

  /// The single removal path for native devices. Idempotent: whichever trigger
  /// fires first (explicit disconnect, the DeviceManager diff, teardown) removes
  /// the entry and emits, later ones find it gone. Explicit and unexpected
  /// removals are indistinguishable to the client.
  void _removeNativeDevice(String deviceId) {
    var device = _connectedDevices.remove(deviceId);
    if (device == null) return;
    device.close();
    _setupStreamController.add("deviceDisconnected");
    _deviceDisconnectedController.add(device);
  }

  @override
  void teardown() {
    // Note: the shared native MIDI-in callback (_midiCB) is intentionally NOT
    // closed here. It is a process-lifetime callback whose address is baked into
    // every WindowsMidiDevice, so closing it would invalidate reconnection. This
    // (singleton) instance must stay reusable after teardown, which only
    // disconnects devices per the documented contract.
    _connectedDevices.keys.toList().forEach(_removeNativeDevice);
    _bleManager.teardown();
    // Do not close _rxStreamController here: teardown only disconnects devices.
    // Closing the broadcast controller would leave this (singleton) instance
    // unusable for any later connect/sendData.
  }

  /// Sends data to the currently connected devices or a specific midi device
  ///
  /// Data is an UInt8List of individual MIDI command bytes.
  @override
  void sendData(Uint8List data, {int? timestamp, String? deviceId}) {
    if (deviceId != null) {
      // Send to specific device, if present
      _connectedDevices[deviceId]?.send(data);

      var bleDevice = _bleManager.devices[deviceId];
      if (bleDevice != null && bleDevice.connected) bleDevice.send(data);
    } else {
      // Send to all devices
      _connectedDevices.values.forEach((device) {
        device.send(data);
      });

      _bleManager.devices.values.where((element) => element.connected).forEach((
        element,
      ) {
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
    _ensureDeviceManager();
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
    return null;
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
    _connectedDevices.keys
        .where((id) => !presentIds.contains(id))
        .toList()
        .forEach(_removeNativeDevice);
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

// win32 6.x's MIDIINPROC typedef uses the HMIDIIN extension type, which is not
// a valid dart:ffi native function type for NativeCallable. Spell out the raw
// native signature (matching MIDIINPROC's ABI) instead.
final _midiCB =
    NativeCallable<
      Void Function(IntPtr, Uint32, IntPtr, IntPtr, IntPtr)
    >.listener(_onMidiData);

const int MHDR_DONE = 0x00000001;
const int MHDR_PREPARED = 0x00000002;
const int MHDR_INQUEUE = 0x00000004;

void _onMidiData(
  int hMidiIn,
  int wMsg,
  int dwInstance,
  int dwParam1,
  int dwParam2,
) {
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

        // Reassembly is handled per-device so concurrent SysEx from different
        // devices can't corrupt a shared buffer.
        dev?.handleSysexData(messageData, midiHdrPointer);
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
