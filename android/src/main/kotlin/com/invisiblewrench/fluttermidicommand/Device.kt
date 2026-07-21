package com.invisiblewrench.fluttermidicommand

import android.bluetooth.BluetoothDevice
import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiReceiver

abstract class Device {
    var id:String
    var type:String
    lateinit var midiDevice: MidiDevice
    protected var receiver:MidiReceiver? = null
    protected var setupStreamHandler: FMCStreamHandler? = null
    var disconnectStreamHandler: FMCStreamHandler? = null

    /// Device identity sent to clients when the device disconnects.
    open val deviceInfo: Map<String, Any?>
        get() = mapOf("id" to id, "name" to null, "type" to type)

    constructor(id: String, type: String) {
        this.id = id
        this.type = type
    }

    abstract fun connectWithStreamHandler(streamHandler: FMCStreamHandler, onSuccess: () -> Unit, onFailure: (String) -> Unit)

    abstract fun send(data: ByteArray, timestamp: Long?)

    abstract fun close()

    companion object {
        /// The BluetoothMidiService-backed MidiDeviceInfo does not reliably report
        /// TYPE_BLUETOOTH, so identity is derived from the presence of the
        /// bluetooth device property instead of the reported type. Getting this
        /// wrong gives a BLE device a numeric id, which stops it deduping against
        /// its scan-side entry and breaks sendData/disconnectDevice by address.
        fun bluetoothDeviceForInfo(info: MidiDeviceInfo): BluetoothDevice? =
            info.properties.get(MidiDeviceInfo.PROPERTY_BLUETOOTH_DEVICE) as? BluetoothDevice

        fun isBluetoothInfo(info: MidiDeviceInfo): Boolean = bluetoothDeviceForInfo(info) != null

        fun deviceIdForInfo(info: MidiDeviceInfo): String =
            bluetoothDeviceForInfo(info)?.address ?: info.id.toString()
    }
}
