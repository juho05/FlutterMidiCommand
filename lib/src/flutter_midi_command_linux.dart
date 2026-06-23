import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import 'alsa/alsa_midi_device.dart';
import 'ble_midi_device.dart';
import 'midi_command_platform_interface.dart';

class LinuxMidiDevice extends MidiDevice {
  StreamController<MidiPacket> _rxStreamCtrl;
  int cardId;
  int deviceId;
  AlsaMidiDevice _device;
  StreamSubscription? _rxSubscription;

  LinuxMidiDevice(this._device, this.cardId, this.deviceId, String name, String type,
      this._rxStreamCtrl, bool connected)
      : super(
          AlsaMidiDevice.hardwareId(cardId, deviceId),
          name,
          type,
          connected,
        ) {
    // Get input, output ports
    var i = 0;
    _device.inputPorts.toList().forEach((element) {
      inputPorts.add(MidiPort(++i, MidiPortType.IN));
    });
    i = 0;
    _device.outputPorts.toList().forEach((element) {
      outputPorts.add(MidiPort(++i, MidiPortType.OUT));
    });
  }

  Future<bool> connect() async {
    final success = await _device.connect();
    if (!success) {
      connected = false;
      return false;
    }
    connected = true;

    // connect up incoming alsa midi data to our rx stream of MidiPackets
    _rxSubscription = _device.receivedMessages.listen((event) {
      _rxStreamCtrl.add(MidiPacket(event.data, event.timestamp, this));
    });
    return true;
  }

  send(buffer, int length) {
    _device.send(buffer);
  }

  disconnect() {
    _rxSubscription?.cancel();
    _rxSubscription = null;
    _device.disconnect();
    connected = false;
  }
}

class FlutterMidiCommandLinux extends MidiCommandPlatform {
  StreamController<MidiPacket> _rxStreamController = StreamController<MidiPacket>.broadcast();
  late Stream<MidiPacket> _rxStream;
  StreamController<String> _setupStreamController = StreamController<String>.broadcast();
  late Stream<String> _setupStream;
  StreamController<MidiDevice> _deviceDisconnectedController = StreamController<MidiDevice>.broadcast();
  late Stream<MidiDevice> _deviceDisconnectedStream;

  StreamController<String> _bluetoothStateStreamController = StreamController<String>.broadcast();
  late Stream<String> _bluetoothStateStream;

  Map<String, LinuxMidiDevice> _connectedDevices = Map<String, LinuxMidiDevice>();

  String _bleState = "unknown";
  Map<String, BLEMidiDevice> _discoveredBLEDevices = {};

  /// A constructor that allows tests to override the window object used by the plugin.
  FlutterMidiCommandLinux() {
    _setupStream = _setupStreamController.stream;
    _rxStream = _rxStreamController.stream;
    _deviceDisconnectedStream = _deviceDisconnectedController.stream;
    _bluetoothStateStream = _bluetoothStateStreamController.stream;

    // Notify clients when a connected device is unexpectedly removed (e.g.
    // unplugged). For an explicit disconnect the device has already been removed
    // from [_connectedDevices] (and the event emitted) in disconnectDevice, so
    // this only fires for unexpected drops.
    AlsaMidiDevice.onDeviceDisconnected.listen((alsaDevice) {
      var id = AlsaMidiDevice.hardwareId(alsaDevice.cardId, alsaDevice.deviceId);
      var device = _connectedDevices.remove(id);
      if (device != null) {
        // The underlying ALSA device is already torn down; this just cancels our
        // rx subscription and marks the wrapper disconnected.
        device.disconnect();
        _deviceDisconnectedController.add(device);
        _setupStreamController.add("deviceDisconnected");
      }
    });
  }

  /// The linux implementation of [MidiCommandPlatform]
  ///
  /// This class implements the `package:flutter_midi_command_platform_interface` functionality for linux
  static void registerWith() {
    print("register FlutterMidiCommandLinux");
    MidiCommandPlatform.instance = FlutterMidiCommandLinux();
  }

  @override
  Future<List<MidiDevice>> get devices async {
    // Enumerate fresh each time so unplugged/replugged devices aren't served
    // from a stale cache. getDevices() already returns the live objects for
    // currently-connected devices, so connections are preserved.
    List<MidiDevice> devices = AlsaMidiDevice.getDevices()
        .map<MidiDevice>(
          (alsMidiDevice) => LinuxMidiDevice(
            alsMidiDevice,
            alsMidiDevice.cardId,
            alsMidiDevice.deviceId,
            alsMidiDevice.name,
            "native",
            _rxStreamController,
            _connectedDevices.containsKey(
                AlsaMidiDevice.hardwareId(alsMidiDevice.cardId, alsMidiDevice.deviceId)),
          ),
        )
        .toList();

    // Append BLE devices discovered/connected via the (cross-platform)
    // universal_ble backend, which uses BlueZ on Linux.
    devices.addAll(_discoveredBLEDevices.values);

    return devices;
  }


  /// Prepares Bluetooth system
  ///
  /// On Linux this drives the BlueZ stack through the (cross-platform)
  /// universal_ble backend. Requires a running bluetoothd.
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

    UniversalBle.onValueChange = (deviceId, characteristicId, Uint8List data, int? timestamp) {
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
  @override
  Future<void> startScanningForBluetoothDevices() async {
    try {
      await UniversalBle.startScan(
          scanFilter: ScanFilter(withServices: [MIDI_SERVICE_ID]));
    } catch (e) {
      print(e.toString());
    }
  }

  /// Stops scanning for BLE MIDI devices.
  @override
  void stopScanningForBluetoothDevices() {
    UniversalBle.stopScan();

    // Prune discovered-but-not-connected devices so a later [devices] call no
    // longer lists BLE peripherals that went out of range while scanning (BLE
    // provides no "scan result removed" event, so this is the point at which we
    // know the discovered set is stale). Connected devices are kept since the
    // active session - data reception and disconnect - relies on their entry
    // here. Mirrors the Windows backend.
    _discoveredBLEDevices.removeWhere((_, device) => !device.connected);
  }

  /// Connects to the device.
  @override
  Future<void> connectToDevice(MidiDevice device, {List<MidiPort>? ports}) async {
    print('connect to $device');

    if (device is BLEMidiDevice) {
      // The connected event is emitted from the onConnectionChange callback.
      device.connect();
      return;
    }

    var linuxDevice = device as LinuxMidiDevice;
    final success = await linuxDevice.connect();
    if (success) {
      _connectedDevices[device.id] = device;
      _setupStreamController.add("deviceConnected");
    } else {
      print("failed to connect $linuxDevice");
    }
  }

  /// Disconnects from the device.
  @override
  void disconnectDevice(MidiDevice device, {bool remove = true}) {
    if (device is BLEMidiDevice) {
      // The disconnect event is emitted from the onConnectionChange callback.
      device.disconnect();
      return;
    }

    // Operate on the stored connected device, not the passed-in wrapper, which
    // may be a fresh instance from a later devices() enumeration wrapping the
    // same underlying device.
    var linuxDevice = _connectedDevices[device.id];
    if (linuxDevice != null) {
      linuxDevice.disconnect();
      if (remove) {
        _connectedDevices.remove(device.id);
        _setupStreamController.add("deviceDisconnected");
        _deviceDisconnectedController.add(linuxDevice);
      }
    }
  }

  @override
  void teardown() {
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
    // Do not close _rxStreamController here: teardown only disconnects devices
    // (matching the documented contract and the darwin/Android backends).
    // Closing the broadcast controller would leave the plugin instance unusable
    // for any later connect/sendData on the same instance.
  }

  /// Sends data to the currently connected device.wmidi hardware driver name
  ///
  /// Data is an UInt8List of individual MIDI command bytes.
  @override
  void sendData(Uint8List data, {int? timestamp, String? deviceId}) {
    if (deviceId != null) {
      // Send to a specific device, if present.
      _connectedDevices[deviceId]?.send(data, data.length);

      _discoveredBLEDevices.values
          .where((device) => device.deviceId == deviceId)
          .forEach((device) {
        device.send(data);
      });
    } else {
      // Send to all connected devices.
      _connectedDevices.values.forEach((device) {
        // print("send to $device");
        device.send(data, data.length);
      });

      _discoveredBLEDevices.values
          .where((device) => device.connected)
          .forEach((device) {
        device.send(data);
      });
    }
  }

  /// Stream firing events whenever a midi package is received.
  ///
  /// The event contains the raw bytes contained in the MIDI package.
  @override
  Stream<MidiPacket>? get onMidiDataReceived {
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
  }

  /// Removes a previously addd virtual MIDI source.
  @override
  void removeVirtualDevice({String? name}) {
    // Not implemented
  }
}
