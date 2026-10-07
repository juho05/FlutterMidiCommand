import 'dart:async';

import 'package:dbus/dbus.dart';

const _deviceInterface = 'org.bluez.Device1';
const _batteryInterface = 'org.bluez.Battery1';

/// BlueZ claims the battery service of a peripheral for itself and hides it
/// from GATT clients, publishing the level as org.bluez.Battery1 on the device
/// object instead. This follows that interface for every device BlueZ knows.
class BluezBatteryWatcher {
  BluezBatteryWatcher(this.onLevel);

  /// Called with the address of the device and its charge in percent.
  final void Function(String deviceId, int level) onLevel;

  DBusClient? _client;
  final Map<DBusObjectPath, String> _addresses = {};
  final Map<DBusObjectPath, int> _levels = {};

  /// The level BlueZ currently publishes for [deviceId], if any.
  int? levelFor(String deviceId) {
    for (var entry in _levels.entries) {
      if (_addresses[entry.key] == deviceId) return entry.value;
    }
    return null;
  }

  Future<void> start() async {
    if (_client != null) return;
    var client = _client = DBusClient.system();
    var manager = DBusRemoteObjectManager(
      client,
      name: 'org.bluez',
      path: DBusObjectPath('/'),
    );
    // Listen before the initial read so nothing published in between is lost.
    manager.signals.listen(_handleSignal, onError: (e) {
      print('bluez battery watch failed: $e');
    });
    try {
      (await manager.getManagedObjects()).forEach(_handleInterfaces);
    } catch (e) {
      print('failed to read bluez battery levels: $e');
    }
  }

  void _handleSignal(DBusSignal signal) {
    if (signal is DBusObjectManagerInterfacesAddedSignal) {
      _handleInterfaces(signal.changedPath, signal.interfacesAndProperties);
    } else if (signal is DBusObjectManagerInterfacesRemovedSignal) {
      // Battery1 goes away on disconnect, the level it carried is stale then.
      if (signal.interfaces.contains(_batteryInterface)) {
        _levels.remove(signal.changedPath);
      }
      if (signal.interfaces.contains(_deviceInterface)) {
        _addresses.remove(signal.changedPath);
      }
    } else if (signal is DBusPropertiesChangedSignal &&
        signal.propertiesInterface == _batteryInterface) {
      _handleBattery(signal.path, signal.changedProperties);
    }
  }

  void _handleInterfaces(
    DBusObjectPath path,
    Map<String, Map<String, DBusValue>> interfaces,
  ) {
    var address = interfaces[_deviceInterface]?['Address'];
    if (address is DBusString) _addresses[path] = address.value;
    _handleBattery(path, interfaces[_batteryInterface]);
  }

  void _handleBattery(DBusObjectPath path, Map<String, DBusValue>? properties) {
    var percentage = properties?['Percentage'];
    if (percentage is! DBusByte) return;
    _levels[path] = percentage.value;
    var address = _addresses[path];
    if (address != null) onLevel(address, percentage.value);
  }
}
