package com.invisiblewrench.fluttermidicommand

import android.bluetooth.*
import android.content.Context
import android.os.Build
import android.util.Log
import java.util.UUID

/// Reads the standard battery service of a BLE MIDI device. The MIDI link is
/// owned by the system's BluetoothMidiService, which does not expose it, so
/// this registers a GATT client of its own on the same link. Best effort: a
/// device without a battery service simply never reports.
@Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
class BatteryMonitor(private val onLevel: (Int) -> Unit) {
    private val batteryServiceUuid = UUID.fromString("0000180f-0000-1000-8000-00805f9b34fb")
    private val batteryLevelUuid = UUID.fromString("00002a19-0000-1000-8000-00805f9b34fb")
    private val clientConfigUuid = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    private var gatt: BluetoothGatt? = null
    @Volatile private var stopped = false
    private var lastLevel: Int? = null

    fun start(context: Context, device: BluetoothDevice) {
        try {
            gatt = if (Build.VERSION.SDK_INT >= 23) {
                device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
            } else {
                device.connectGatt(context, false, callback)
            }
        } catch (e: Exception) {
            Log.w("FlutterMIDICommand", "Battery monitor failed to start: $e")
        }
    }

    /// Only releases this client, the link itself stays with its other holders.
    fun stop() {
        stopped = true
        try {
            gatt?.close()
        } catch (e: Exception) {
            Log.w("FlutterMIDICommand", "Battery monitor failed to stop: $e")
        }
        gatt = null
    }

    private fun report(characteristic: BluetoothGattCharacteristic, value: ByteArray?) {
        if (stopped || characteristic.uuid != batteryLevelUuid || value == null || value.isEmpty()) return
        val level = (value[0].toInt() and 0xFF).coerceAtMost(100)
        if (level == lastLevel) return
        lastLevel = level
        onLevel(level)
    }

    private fun subscribe(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
        if (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY == 0) return
        gatt.setCharacteristicNotification(characteristic, true)
        val descriptor = characteristic.getDescriptor(clientConfigUuid) ?: return
        if (Build.VERSION.SDK_INT >= 33) {
            gatt.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
        } else {
            descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            gatt.writeDescriptor(descriptor)
        }
    }

    private fun guarded(block: () -> Unit) {
        if (stopped) return
        try {
            block()
        } catch (e: Exception) {
            Log.w("FlutterMIDICommand", "Battery monitor error: $e")
        }
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) = guarded {
            if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
                gatt.discoverServices()
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) = guarded {
            gatt.getService(batteryServiceUuid)?.getCharacteristic(batteryLevelUuid)?.also {
                gatt.readCharacteristic(it)
            }
        }

        // Both generations of the value callbacks: API 33+ only calls the new
        // ones, older versions only know the deprecated ones.
        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) = guarded {
            if (status == BluetoothGatt.GATT_SUCCESS) report(characteristic, characteristic.value)
            subscribe(gatt, characteristic)
        }

        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) = guarded {
            if (status == BluetoothGatt.GATT_SUCCESS) report(characteristic, value)
            subscribe(gatt, characteristic)
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) = guarded {
            report(characteristic, characteristic.value)
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) = guarded {
            report(characteristic, value)
        }
    }
}
