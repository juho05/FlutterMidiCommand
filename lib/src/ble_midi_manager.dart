import 'dart:async';

import 'package:flutter/services.dart';
import 'package:universal_ble/universal_ble.dart';

import 'ble_midi_device.dart';
import 'midi_command_platform_interface.dart';

/// Timing shared by all four backends, see platform-matching.md.
const bleConnectTimeout = Duration(seconds: 15);
const bleCharacteristicGrace = Duration(seconds: 10);
const bleConnectGrace = Duration(seconds: 1);
const reconcileInterval = Duration(seconds: 5);
const reconcileDebounce = Duration(seconds: 1);

/// Drives the BLE half of the two pure-Dart backends (Linux and Windows). Both
/// talk to the same `universal_ble` stack, so discovery, connect and disconnect
/// behave identically on either and live here rather than in each backend.
///
/// The manager owns the discovered set. A connected device stays in it so the
/// active session keeps being listed and can still receive data, mirroring the
/// darwin backend where a connected peripheral is listed even once it stops
/// advertising.
class BleMidiManager {
  BleMidiManager({
    required StreamController<MidiPacket> rxStreamController,
    required this.onSetupEvent,
    required this.onDeviceDisconnected,
    required this.onBluetoothState,
  }) : _rxStreamController = rxStreamController;

  final StreamController<MidiPacket> _rxStreamController;

  /// Emits the shared setup vocabulary: deviceAppeared, deviceDisappeared,
  /// deviceConnected, deviceDisconnected, connectionFailed.
  final void Function(String event) onSetupEvent;
  final void Function(MidiDevice device) onDeviceDisconnected;
  final void Function(String state) onBluetoothState;

  final Map<String, BLEMidiDevice> _devices = {};

  /// The discovered set, which also holds the currently connected devices.
  Map<String, BLEMidiDevice> get devices => _devices;

  String _state = "unknown";
  String get state => _state;

  bool _started = false;

  /// Whether the app currently wants a scan. A connect stops the scanner while
  /// a scan is still wanted, so an idle scanner is not the same as "no scan".
  bool _scanRequested = false;

  final Set<String> _ongoingConnections = {};
  Timer? _reconcileTimer;
  DateTime? _lastReconcile;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    UniversalBle.timeout = const Duration(seconds: 10);

    UniversalBle.onAvailabilityChange = _handleAvailability;

    UniversalBle.onScanResult = (result) {
      var name = result.name;
      if (name != null && !_devices.containsKey(result.deviceId)) {
        _devices[result.deviceId] = BLEMidiDevice(
          result.deviceId,
          name,
          _rxStreamController,
        );
        onSetupEvent('deviceAppeared');
      }
      // A fresh advertisement is the moment a stale connected/discovered pair
      // materializes, so reconcile (debounced against discovery bursts).
      _triggerReconcile();
    };

    UniversalBle.onConnectionChange = (deviceId, isConnected, error) {
      // A successful connect is reported by [connect] itself, which only
      // resolves once the device is genuinely usable. Anything arriving here
      // for a device we are not connected to is a drop we have already handled,
      // or one for a device that never got connected in the first place.
      if (isConnected) return;
      var device = _devices[deviceId];
      if (device != null) _handleDisconnected(device);
    };

    UniversalBle.onValueChange = (deviceId, characteristicId, data, timestamp) {
      _devices[deviceId]?.handleData(data);
    };

    UniversalBle.onPairingStateChange = (deviceId, isPaired) {
      _devices[deviceId]?.pairingState = isPaired;
    };

    // Publish the current state up front. universal_ble reports it through
    // onAvailabilityChange as well, but only after an async round trip, so
    // without this a bluetoothState() right after this call answers "unknown".
    try {
      _handleAvailability(await UniversalBle.getBluetoothAvailabilityState());
    } catch (e) {
      // Reading the state throws when there is no stack to read it from (no
      // adapter, no bluetoothd), which to a client is indistinguishable from an
      // unsupported adapter. Report that rather than leaving the state at
      // "unknown", which is the pre-init value and would hang a wait on it.
      print('failed to read bluetooth availability: $e');
      _handleAvailability(AvailabilityState.unsupported);
    }
  }

  void _handleAvailability(AvailabilityState state) {
    var wasPoweredOn = _state == AvailabilityState.poweredOn.name;
    _state = state.name;
    onBluetoothState(state.name);

    if (state == AvailabilityState.poweredOn) {
      // The reaping below deliberately leaves _scanRequested set, so a scan the
      // app asked for survives an adapter off/on cycle and is picked up here.
      if (!wasPoweredOn) _resumeAfterPowerOn();
      return;
    }

    // Anything other than poweredOn invalidates every peripheral, so all BLE
    // state is reaped event-driven rather than waiting for a reconcile.
    // "unknown" is the pre-init state, where there is nothing to reap yet.
    if (state == AvailabilityState.unknown) return;

    _stopReconcileTimer();
    // The whole set goes below, so skip the per-device discovered refresh.
    _devices.values.where((device) => device.connected).toList().forEach((
      device,
    ) {
      _handleDisconnected(device, refreshDiscovered: false);
    });
    if (_devices.isNotEmpty) {
      _devices.clear();
      onSetupEvent('deviceDisappeared');
    }
  }

  /// Starts scanning for BLE MIDI devices. Throws when Bluetooth is not
  /// available, rather than silently scanning into the void.
  Future<void> startScanning() async {
    await start();
    if (_state != AvailabilityState.poweredOn.name) {
      throw PlatformException(
        code: 'MESSAGEERROR',
        message: 'bluetoothNotAvailable',
        details: _state,
      );
    }

    // Set before seeding: the seed reads the system asynchronously and bails if
    // no scan is wanted by the time it comes back.
    _scanRequested = true;
    await _seedSystemDevices();
    _startReconcileTimer();
    await UniversalBle.startScan(
      scanFilter: ScanFilter(withServices: [MIDI_SERVICE_ID]),
    );
  }

  /// Seeds peripherals the system already holds, so a device connected by
  /// another app (or before this process started) still surfaces.
  Future<void> _seedSystemDevices() async {
    try {
      var systemDevices = await UniversalBle.getSystemDevices(
        withServices: [MIDI_SERVICE_ID],
      );
      for (var device in systemDevices) {
        // The scan may have been stopped while the read was in flight; adding
        // then would resurrect entries stopScanning just pruned.
        if (!_scanRequested) return;
        if (_devices.containsKey(device.deviceId)) continue;
        _devices[device.deviceId] = BLEMidiDevice(
          device.deviceId,
          device.name ?? device.deviceId,
          _rxStreamController,
        );
        onSetupEvent('deviceAppeared');
      }
    } catch (e) {
      print('failed to read system devices: $e');
    }
  }

  void stopScanning() {
    _scanRequested = false;
    _stopReconcileTimer();
    UniversalBle.stopScan();

    // Prune discovered-but-not-connected devices so a later devices call no
    // longer lists BLE peripherals that went out of range while scanning (BLE
    // provides no "scan result removed" event, so this is the point at which we
    // know the discovered set is stale). Connected devices survive.
    _devices.removeWhere((_, device) => !device.connected);
  }

  /// Rebuilds the scan state the adapter going off tore down. Same sequence as
  /// [startScanning], minus the state check and the request flag, which the
  /// earlier scan already set.
  Future<void> _resumeAfterPowerOn() async {
    if (!_scanRequested) return;
    await _seedSystemDevices();
    _startReconcileTimer();
    await _resumeScanIfNeeded();
  }

  Future<void> _resumeScanIfNeeded() async {
    if (!_scanRequested || _state != AvailabilityState.poweredOn.name) return;
    try {
      await UniversalBle.startScan(
        scanFilter: ScanFilter(withServices: [MIDI_SERVICE_ID]),
      );
    } catch (e) {
      print('failed to resume scan: $e');
    }
  }

  /// Connects to [device]. The returned future resolves only once the device is
  /// genuinely usable, ie. its MIDI characteristic has been discovered and
  /// subscribed to, and throws a [PlatformException] otherwise.
  Future<void> connect(BLEMidiDevice device) async {
    var deviceId = device.deviceId;
    // Operate on the stored device: the caller may hold a wrapper from an
    // earlier enumeration while the stored one owns the session state.
    var stored = _devices[deviceId];
    if (stored == null) {
      // Nothing discovered under this id, but the peripheral may well still be
      // there: the discovered set is pruned on scan stop and on disconnect, and
      // a device held by another app never has to be discovered at all. The id
      // is all that is needed to open the link, so adopt the caller's device
      // rather than refusing, matching the android backend's fallback.
      stored = device;
      _devices[deviceId] = device;
      onSetupEvent('deviceAppeared');
    }
    if (stored.connected) {
      throw PlatformException(
        code: 'MESSAGEERROR',
        message: 'Device already connected',
        details: deviceId,
      );
    }
    if (!_ongoingConnections.add(deviceId)) {
      throw PlatformException(
        code: 'MESSAGEERROR',
        message: 'Connection already in progress',
        details: deviceId,
      );
    }

    stored.connectRequestTime = DateTime.now();

    try {
      // Scanning throttles the link setup and on some stacks makes it fail
      // outright, so pause it for the attempt and resume afterwards. Inside the
      // try: a throw here has to release the in-progress marker too, or the
      // device could never be connected to again.
      if (_scanRequested) await UniversalBle.stopScan();
      await UniversalBle.connect(deviceId, timeout: bleConnectTimeout);
      if (!await stored.discoverMidiService(timeout: bleCharacteristicGrace)) {
        throw PlatformException(
          code: 'MESSAGEERROR',
          message: 'No BLE MIDI characteristic',
          details: deviceId,
        );
      }
    } catch (e) {
      await _abortConnect(stored);
      _ongoingConnections.remove(deviceId);
      onSetupEvent('connectionFailed');
      await _resumeScanIfNeeded();
      if (e is PlatformException) rethrow;
      throw PlatformException(
        code: 'MESSAGEERROR',
        message: e.toString(),
        details: deviceId,
      );
    }

    _ongoingConnections.remove(deviceId);
    stored.connected = true;
    onSetupEvent('deviceConnected');
    await _resumeScanIfNeeded();
  }

  /// Tears down a failed attempt. The device was never marked connected, so
  /// this emits connectionFailed (from [connect]) rather than a disconnect.
  Future<void> _abortConnect(BLEMidiDevice device) async {
    await device.unsubscribe();
    try {
      await UniversalBle.disconnect(device.deviceId);
    } catch (e) {
      print('failed to cancel connect for ${device.deviceId}: $e');
    }
  }

  Future<void> disconnect(BLEMidiDevice device) async {
    var stored = _devices[device.deviceId] ?? device;
    await stored.unsubscribe();
    try {
      await UniversalBle.disconnect(stored.deviceId);
    } catch (e) {
      print('failed to disconnect ${stored.deviceId}: $e');
    }
    // Idempotent, and the onConnectionChange callback may well have got here
    // first; whichever runs first emits, the other one finds it already gone.
    _handleDisconnected(stored);
  }

  /// The single removal path. Explicit disconnect and unexpected drop are
  /// indistinguishable to the client, and each removal emits exactly once.
  void _handleDisconnected(
    BLEMidiDevice device, {
    bool refreshDiscovered = true,
  }) {
    if (!device.connected) return;
    device.handleDisconnected();
    onSetupEvent('deviceDisconnected');
    onDeviceDisconnected(device);

    // Drop the removed device from the discovered set so it can be reported as
    // appearing again, which is what drives app-side auto-reconnect. No scan
    // restart as on darwin: neither BlueZ nor WinRT de-duplicates within a scan
    // session, so a device that is still present re-enters the set on its next
    // advertisement, while one that is really gone stays absent.
    if (refreshDiscovered) _devices.remove(device.deviceId);
  }

  /// Drops entries that are marked connected but are not - the link dropped
  /// while nothing was watching - and half-open links that never produced a
  /// MIDI characteristic.
  Future<void> reconcile() async {
    for (var device
        in _devices.values.where((device) => device.connected).toList()) {
      var elapsed = DateTime.now().difference(device.connectRequestTime);
      if (elapsed < bleConnectGrace) continue;

      BleConnectionState state;
      try {
        state = await UniversalBle.getConnectionState(device.deviceId);
      } catch (e) {
        continue;
      }

      if (state == BleConnectionState.disconnected) {
        print('reconcile: ${device.deviceId} is no longer connected');
        _handleDisconnected(device);
      } else if (state == BleConnectionState.connected &&
          !device.hasMidiCharacteristic &&
          elapsed > bleCharacteristicGrace) {
        print('reconcile: ${device.deviceId} is half open, disconnecting');
        await disconnect(device);
      }
    }
  }

  /// Debounced reconcile for the scan-driven entry points (the repeating timer
  /// and every scan result), so discovery bursts coalesce into one pass.
  void _triggerReconcile() {
    var last = _lastReconcile;
    if (last != null && DateTime.now().difference(last) < reconcileDebounce) {
      return;
    }
    _lastReconcile = DateTime.now();
    reconcile();
  }

  void _startReconcileTimer() {
    _reconcileTimer ??= Timer.periodic(
      reconcileInterval,
      (_) => _triggerReconcile(),
    );
  }

  void _stopReconcileTimer() {
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
  }

  /// Disconnects everything and stops scanning, leaving the manager reusable.
  Future<void> teardown() async {
    stopScanning();
    for (var device
        in _devices.values.where((device) => device.connected).toList()) {
      await disconnect(device);
    }
  }
}
