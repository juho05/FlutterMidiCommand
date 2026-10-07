import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'alsa/alsa_midi_device.dart';
import 'ble_midi_device.dart';
import 'ble_midi_manager.dart';
import 'midi_command_platform_interface.dart';

class LinuxMidiDevice extends MidiDevice {
  StreamController<MidiPacket> _rxStreamCtrl;
  int cardId;
  int deviceId;
  AlsaMidiDevice _device;
  StreamSubscription? _rxSubscription;

  LinuxMidiDevice(
    this._device,
    this.cardId,
    this.deviceId,
    String name,
    String type,
    this._rxStreamCtrl,
    bool connected,
  ) : super(
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
  StreamController<MidiPacket> _rxStreamController =
      StreamController<MidiPacket>.broadcast();
  late Stream<MidiPacket> _rxStream;
  StreamController<String> _setupStreamController =
      StreamController<String>.broadcast();
  late Stream<String> _setupStream;
  StreamController<MidiDevice> _deviceDisconnectedController =
      StreamController<MidiDevice>.broadcast();
  late Stream<MidiDevice> _deviceDisconnectedStream;
  StreamController<MidiDevice> _batteryLevelController =
      StreamController<MidiDevice>.broadcast();

  StreamController<String> _bluetoothStateStreamController =
      StreamController<String>.broadcast();
  late Stream<String> _bluetoothStateStream;

  Map<String, LinuxMidiDevice> _connectedDevices =
      Map<String, LinuxMidiDevice>();

  late final BleMidiManager _bleManager;

  /// The ALSA device ids seen by the last enumeration, diffed against a fresh
  /// one to turn a /dev/snd change into appear/disappear events. Null until the
  /// first enumeration, which only seeds it.
  Set<String>? _knownNativeIds;
  StreamSubscription<FileSystemEvent>? _sndWatch;
  Timer? _sndDebounce;

  /// A constructor that allows tests to override the window object used by the plugin.
  FlutterMidiCommandLinux() {
    _setupStream = _setupStreamController.stream;
    _rxStream = _rxStreamController.stream;
    _deviceDisconnectedStream = _deviceDisconnectedController.stream;
    _bluetoothStateStream = _bluetoothStateStreamController.stream;

    _bleManager = BleMidiManager(
      rxStreamController: _rxStreamController,
      onSetupEvent: (event) => _setupStreamController.add(event),
      onDeviceDisconnected: (device) =>
          _deviceDisconnectedController.add(device),
      onBatteryLevel: (device) => _batteryLevelController.add(device),
      onBluetoothState: (state) => _bluetoothStateStreamController.add(state),
    );

    // Notify clients when a connected device is unexpectedly removed (e.g.
    // unplugged). The underlying ALSA device is already torn down by the time
    // this fires; the removal path below just cancels our rx subscription,
    // marks the wrapper disconnected and emits.
    AlsaMidiDevice.onDeviceDisconnected.listen((alsaDevice) {
      _removeNativeDevice(
        AlsaMidiDevice.hardwareId(alsaDevice.cardId, alsaDevice.deviceId),
      );
    });

    _startNativeDeviceWatch();
  }

  /// The linux implementation of [MidiCommandPlatform]
  ///
  /// This class implements the `package:flutter_midi_command_platform_interface` functionality for linux
  static void registerWith() {
    print("register FlutterMidiCommandLinux");
    MidiCommandPlatform.instance = FlutterMidiCommandLinux();
  }

  /// ALSA has no hot-plug notification of its own, so watch the device nodes
  /// instead: the kernel creates and removes /dev/snd/midiC*D* as cards come and
  /// go. This is what CoreMIDI's notifications are on darwin and DeviceManager
  /// is on Windows, without polling ALSA on a timer.
  void _startNativeDeviceWatch() {
    if (_sndWatch != null) return;
    try {
      _sndWatch = Directory('/dev/snd')
          .watch(events: FileSystemEvent.create | FileSystemEvent.delete)
          .listen(
            (_) {
              // A single plug event churns several nodes and the MIDI one does
              // not necessarily come last, so coalesce before enumerating.
              _sndDebounce?.cancel();
              _sndDebounce = Timer(reconcileDebounce, _refreshNativeDevices);
            },
            onError: (e) {
              print("failed to watch /dev/snd: $e");
            },
          );
    } catch (e) {
      print("failed to watch /dev/snd: $e");
    }
  }

  /// Diffs the present ALSA devices against the last enumeration and emits the
  /// appear/disappear events, plus a disconnect for every connected device that
  /// vanished.
  void _refreshNativeDevices() {
    List<AlsaMidiDevice> present;
    try {
      present = AlsaMidiDevice.getDevices();
    } catch (e) {
      print("failed to enumerate ALSA devices: $e");
      return;
    }
    _applyNativeIds(
      present
          .map(
            (device) =>
                AlsaMidiDevice.hardwareId(device.cardId, device.deviceId),
          )
          .toSet(),
    );
  }

  void _applyNativeIds(Set<String> presentIds) {
    var known = _knownNativeIds;
    _knownNativeIds = presentIds;
    if (known == null) return;

    if (presentIds.difference(known).isNotEmpty) {
      _setupStreamController.add("deviceAppeared");
    }

    var removed = known.difference(presentIds);
    for (var id in removed) {
      _removeNativeDevice(id);
    }
    if (removed.isNotEmpty) {
      _setupStreamController.add("deviceDisappeared");
    }
  }

  /// The single removal path for native devices. Idempotent: whichever trigger
  /// fires first (explicit disconnect, the rx isolate noticing the unplug, the
  /// /dev/snd diff, teardown) removes the entry and emits, later ones find it
  /// gone. Explicit and unexpected removals are indistinguishable to the client.
  void _removeNativeDevice(String deviceId) {
    var device = _connectedDevices.remove(deviceId);
    if (device == null) return;
    device.disconnect();
    _setupStreamController.add("deviceDisconnected");
    _deviceDisconnectedController.add(device);
  }

  @override
  Future<List<MidiDevice>> get devices async {
    // Reconcile BLE first so a device that dropped while nothing was watching is
    // never reported as still connected.
    await _bleManager.reconcile();

    // Enumerate fresh each time so unplugged/replugged devices aren't served
    // from a stale cache. getDevices() already returns the live objects for
    // currently-connected devices, so connections are preserved.
    var alsaDevices = AlsaMidiDevice.getDevices();

    // Feed the enumeration we just did into the hot-plug diff before building
    // the list, so a device that vanished is reaped rather than listed as still
    // connected, and so the next /dev/snd change is compared against this state.
    _applyNativeIds(
      alsaDevices
          .map(
            (device) =>
                AlsaMidiDevice.hardwareId(device.cardId, device.deviceId),
          )
          .toSet(),
    );

    List<MidiDevice> devices = alsaDevices
        .map<MidiDevice>(
          (alsMidiDevice) => LinuxMidiDevice(
            alsMidiDevice,
            alsMidiDevice.cardId,
            alsMidiDevice.deviceId,
            alsMidiDevice.name,
            "native",
            _rxStreamController,
            _connectedDevices.containsKey(
              AlsaMidiDevice.hardwareId(
                alsMidiDevice.cardId,
                alsMidiDevice.deviceId,
              ),
            ),
          ),
        )
        .toList();

    // Append BLE devices discovered/connected via the (cross-platform)
    // universal_ble backend, which uses BlueZ on Linux.
    devices.addAll(_bleManager.devices.values);

    return devices;
  }

  /// Prepares Bluetooth system
  ///
  /// On Linux this drives the BlueZ stack through the (cross-platform)
  /// universal_ble backend. Requires a running bluetoothd.
  @override
  Future<void> startBluetoothCentral() async {
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
    print('connect to $device');

    if (device is BLEMidiDevice) {
      return _bleManager.connect(device);
    }

    var linuxDevice = device as LinuxMidiDevice;
    if (_connectedDevices.containsKey(linuxDevice.id)) {
      throw PlatformException(
        code: 'MESSAGEERROR',
        message: 'Device already connected',
        details: linuxDevice.id,
      );
    }

    if (!await linuxDevice.connect()) {
      _setupStreamController.add("connectionFailed");
      throw PlatformException(
        code: 'MESSAGEERROR',
        message: 'Failed to open device',
        details: linuxDevice.id,
      );
    }
    _connectedDevices[linuxDevice.id] = linuxDevice;
    _setupStreamController.add("deviceConnected");
  }

  /// Disconnects from the device.
  @override
  void disconnectDevice(MidiDevice device) {
    if (device is BLEMidiDevice) {
      _bleManager.disconnect(device);
      return;
    }

    // Operate on the stored connected device, not the passed-in wrapper, which
    // may be a fresh instance from a later devices() enumeration wrapping the
    // same underlying device.
    _removeNativeDevice(device.id);
  }

  @override
  void teardown() {
    _connectedDevices.keys.toList().forEach(_removeNativeDevice);
    _bleManager.teardown();
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

      var bleDevice = _bleManager.devices[deviceId];
      if (bleDevice != null && bleDevice.connected) bleDevice.send(data);
    } else {
      // Send to all connected devices.
      _connectedDevices.values.forEach((device) {
        // print("send to $device");
        device.send(data, data.length);
      });

      _bleManager.devices.values.where((device) => device.connected).forEach((
        device,
      ) {
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

  /// Stream firing whenever a connected BLE device reports its battery level.
  @override
  Stream<MidiDevice>? get onBatteryLevelChanged {
    return _batteryLevelController.stream;
  }

  /// Creates a virtual MIDI source
  ///
  /// The virtual MIDI source appears as a virtual port in other apps.
  /// Currently only supported on iOS.
  @override
  void addVirtualDevice({String? name}) {
    // Not implemented
    print('addVirtualDevice not implemented on Linux');
  }

  /// Removes a previously addd virtual MIDI source.
  @override
  void removeVirtualDevice({String? name}) {
    // Not implemented
    print('removeVirtualDevice not implemented on Linux');
  }

  @override
  Future<bool?> get isNetworkSessionEnabled async => null;

  @override
  void setNetworkSessionEnabled(bool enabled) {
    // Not implemented
    print('setNetworkSessionEnabled not implemented on Linux');
  }
}
