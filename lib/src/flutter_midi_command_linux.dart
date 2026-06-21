import 'dart:async';
import 'dart:typed_data';
import 'alsa/alsa_midi_device.dart';
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

  Map<String, LinuxMidiDevice> _connectedDevices = Map<String, LinuxMidiDevice>();

  /// A constructor that allows tests to override the window object used by the plugin.
  FlutterMidiCommandLinux() {
    _setupStream = _setupStreamController.stream;
    _rxStream = _rxStreamController.stream;
    _deviceDisconnectedStream = _deviceDisconnectedController.stream;

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
    return AlsaMidiDevice.getDevices()
        .map(
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
  }


  /// Prepares Bluetooth system
  @override Future<void> startBluetoothCentral() async {
    return Future.error("Not available on linux");
  }

  /// Starts scanning for BLE MIDI devices.
  ///
  /// Found devices will be included in the list returned by [devices].
  Future<void> startScanningForBluetoothDevices() async {
    return Future.error("Not available on linux");
  }

  /// Stops scanning for BLE MIDI devices.
  void stopScanningForBluetoothDevices() {}

  /// Connects to the device.
  @override
  Future<void> connectToDevice(MidiDevice device, {List<MidiPort>? ports}) async {
    print('connect to $device');

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
    _setupStreamController.add("deviceDisconnected");
    _rxStreamController.close();
  }

  /// Sends data to the currently connected device.wmidi hardware driver name
  ///
  /// Data is an UInt8List of individual MIDI command bytes.
  @override
  void sendData(Uint8List data, {int? timestamp, String? deviceId}) {
    _connectedDevices.values.forEach((device) {
      // print("send to $device");
      device.send(data, data.length);
    });
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
