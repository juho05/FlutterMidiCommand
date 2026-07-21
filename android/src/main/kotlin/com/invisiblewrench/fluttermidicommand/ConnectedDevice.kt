package com.invisiblewrench.fluttermidicommand

import android.content.pm.ServiceInfo
import android.media.midi.*
import android.util.Log
import kotlinx.coroutines.*

class ConnectedDevice : Device {
    var inputPort: MidiInputPort? = null
    var outputPort: MidiOutputPort? = null

    val isBluetooth: Boolean
        get() = isBluetoothInfo(midiDevice.info)

    private var isOwnVirtualDevice = false
    private var connectionJob: Job? = null
    private var isClosed = false

    override val deviceInfo: Map<String, Any?>
        get() = mapOf(
            "id" to id,
            "name" to midiDevice.info.properties.getString(MidiDeviceInfo.PROPERTY_NAME),
            "type" to if (isBluetooth) "BLE" else "native"
        )

    constructor(device:MidiDevice, setupStreamHandler: FMCStreamHandler) : super(deviceIdForInfo(device.info), if (isBluetoothInfo(device.info)) "BLE" else "native") {
        this.midiDevice = device
        this.setupStreamHandler = setupStreamHandler
    }

    /// Opens the device's ports off the main thread and reports the outcome
    /// exactly once. The device is usable the moment the ports are open, so
    /// there is no settle delay between opening and reporting success.
    override fun connectWithStreamHandler(streamHandler: FMCStreamHandler, onSuccess: () -> Unit, onFailure: (String) -> Unit) {
        Log.d("FlutterMIDICommand","connectWithHandler")

        // Cancel any existing connection attempt
        connectionJob?.cancel()

        // Move blocking I/O operations to background thread to prevent ANR
        connectionJob = CoroutineScope(Dispatchers.IO).launch {
            try {
                val info = midiDevice.info
                Log.d("FlutterMIDICommand","inputPorts ${info.inputPortCount} outputPorts ${info.outputPortCount}")

                // Initialize receiver on background thread
                receiver = RXReceiver(streamHandler, midiDevice)

                var serviceInfo = info.properties.getParcelable<ServiceInfo>("service_info")
                if (serviceInfo?.name == "com.invisiblewrench.fluttermidicommand.VirtualDeviceService") {
                    Log.d("FlutterMIDICommand", "Own virtual")
                    isOwnVirtualDevice = true
                } else {
                    if (info.inputPortCount > 0) {
                        Log.d("FlutterMIDICommand", "Open input port")
                        // This is the blocking call that can cause ANR - now on background thread
                        inputPort = midiDevice.openInputPort(0)
                        // Null means the port is held by another client. Sending is
                        // then unavailable, but receiving may still work, so the
                        // connection is kept rather than failed.
                        if (inputPort == null) Log.w("FlutterMIDICommand", "Input port unavailable, continuing without it")
                        else Log.d("FlutterMIDICommand", "Input port opened successfully")
                    }
                }

                if (info.outputPortCount > 0) {
                    Log.d("FlutterMIDICommand", "Open output port")
                    // This can also block - keep on background thread
                    outputPort = midiDevice.openOutputPort(0)
                    if (outputPort == null) {
                        Log.w("FlutterMIDICommand", "Output port unavailable, continuing without it")
                    } else {
                        Log.d("FlutterMIDICommand", "Output port opened successfully")
                        outputPort?.connect(receiver)
                    }
                }

                // Only a device that offered ports and yielded none is a failure.
                val offeredPorts = info.inputPortCount > 0 || info.outputPortCount > 0
                if (!isOwnVirtualDevice && offeredPorts && inputPort == null && outputPort == null) {
                    throw Exception("Could not open any port")
                }

                withContext(Dispatchers.Main) { onSuccess() }
            } catch (e: CancellationException) {
                Log.d("FlutterMIDICommand", "Connection cancelled")
                // Don't report cancellation as an error
                throw e
            } catch (e: Exception) {
                Log.e("FlutterMIDICommand", "Failed to open MIDI device: ${e.message}", e)
                withContext(Dispatchers.Main) { onFailure("Failed to open MIDI device: ${e.message}") }
            }
        }
    }

    override fun send(data: ByteArray, timestamp: Long?) {

        if(isOwnVirtualDevice) {
            Log.d("FlutterMIDICommand", "Send to recevier")
            if (timestamp == null)
                this.receiver?.send(data, 0, data.size)
            else
                this.receiver?.send(data, 0, data.size, timestamp)

        } else {
            this.inputPort?.send(data, 0, data.count(), if (timestamp is Long) timestamp else 0)
        }
    }

    override fun close() {
        // Whichever removal trigger fires first emits; later ones find the device
        // already closed and are ignored, so the disconnect events fire exactly once.
        if (isClosed) return
        isClosed = true

        Log.d("FlutterMIDICommand", "Close device - cancelling connection job")
        // Capture device identity before tearing down, while midiDevice.info is still valid
        val info = deviceInfo
        try {
            // Cancel any ongoing connection attempts to prevent leaks
            connectionJob?.cancel()
            connectionJob = null

            Log.d("FlutterMIDICommand", "Flush input port ${this.inputPort}")
            this.inputPort?.flush()
            Log.d("FlutterMIDICommand", "Close input port ${this.inputPort}")
            this.inputPort?.close()
            Log.d("FlutterMIDICommand", "Close output port ${this.outputPort}")
            this.outputPort?.close()
            Log.d("FlutterMIDICommand", "Disconnect receiver ${this.receiver}")
            this.outputPort?.disconnect(this.receiver)
            this.receiver = null
            Log.d("FlutterMIDICommand", "Close device ${this.midiDevice}")
            this.midiDevice.close()
        } catch (e: Exception) {
            // The device may already be gone (e.g. physically removed), so teardown
            // can fail. Swallow it so listeners are still notified of the disconnect.
            Log.w("FlutterMIDICommand", "Error while closing device: $e")
        }

        setupStreamHandler?.send("deviceDisconnected")
        disconnectStreamHandler?.send(info)
    }

    class RXReceiver(stream: FMCStreamHandler, device: MidiDevice) : MidiReceiver() {
        val stream = stream
        var isBluetoothDevice = Device.isBluetoothInfo(device.info)
        val deviceInfo = mapOf(
            "id" to Device.deviceIdForInfo(device.info),
            "name" to device.info.properties.getString(MidiDeviceInfo.PROPERTY_NAME),
            "type" to if (isBluetoothDevice) "BLE" else "native"
        )

        // MIDI parsing
        enum class PARSER_STATE
        {
            HEADER,
            PARAMS,
            SYSEX,
        }

        var parserState = PARSER_STATE.HEADER

        var sysExBuffer = mutableListOf<Byte>()
        var midiBuffer = mutableListOf<Byte>()
        var midiPacketLength:Int = 0
        var statusByte:Byte = 0

        override fun onSend(msg: ByteArray?, offset: Int, count: Int, timestamp: Long) {
            msg?.also {
                var data = it.slice(IntRange(offset, offset + count - 1))
//        Log.d("FlutterMIDICommand", "data sliced $data offset $offset count $count")

                if (data.size > 0) {
                    for (i in 0 until data.size) {
                        var midiByte: Byte = data[i]
                        var midiInt = midiByte.toInt() and 0xFF

//          Log.d("FlutterMIDICommand", "parserState $parserState byte $midiByte")

                        when (parserState) {
                            PARSER_STATE.HEADER -> {
                                if (midiInt == 0xF0) {
                                    parserState = PARSER_STATE.SYSEX
                                    sysExBuffer.clear()
                                    sysExBuffer.add(midiByte)
                                } else if (midiInt and 0x80 == 0x80) {
                                    // some kind of midi msg
                                    statusByte = midiByte
                                    midiPacketLength = lengthOfMessageType(midiInt)
//                Log.d("FlutterMIDICommand", "expected length $midiPacketLength")
                                    midiBuffer.clear()
                                    midiBuffer.add(midiByte)
                                    parserState = PARSER_STATE.PARAMS
                                    finalizeMessageIfComplete(timestamp)
                                } else {
                                    // in header state but no status byte, do running status
                                    midiBuffer.clear()
                                    midiBuffer.add(statusByte)
                                    midiBuffer.add(midiByte)
                                    parserState = PARSER_STATE.PARAMS
                                    finalizeMessageIfComplete(timestamp)
                                }
                            }

                            PARSER_STATE.SYSEX -> {
                                if (midiInt == 0xF0) {
                                    // Android can skip SysEx end bytes, when more sysex messages are coming in succession.
                                    // in an attempt to save the situation, add an end byte to the current buffer and start a new one.
                                    sysExBuffer.add(0xF7.toByte())
//                Log.d("FlutterMIDICommand", "sysex force finalized $sysExBuffer")
                                    stream.send(
                                        mapOf(
                                            "data" to sysExBuffer.toList(),
                                            "timestamp" to timestamp,
                                            "device" to deviceInfo
                                        )
                                    )
                                    sysExBuffer.clear();
                                }
                                sysExBuffer.add(midiByte)
                                if (midiInt == 0xF7) {
                                    // Sysex complete
//                Log.d("FlutterMIDICommand", "sysex complete $sysExBuffer")
                                    stream.send(
                                        mapOf(
                                            "data" to sysExBuffer.toList(),
                                            "timestamp" to timestamp,
                                            "device" to deviceInfo
                                        )
                                    )
                                    parserState = PARSER_STATE.HEADER
                                }
                            }

                            PARSER_STATE.PARAMS -> {
                                midiBuffer.add(midiByte)
                                finalizeMessageIfComplete(timestamp)
                            }
                        }
                    }
                }
            }
        }

        fun finalizeMessageIfComplete(timestamp: Long) {
            if (midiBuffer.size == midiPacketLength) {
//        Log.d("FlutterMIDICommand", "status complete $midiBuffer")
                stream.send( mapOf("data" to midiBuffer.toList(), "timestamp" to timestamp, "device" to deviceInfo))
                parserState = PARSER_STATE.HEADER
            }
        }

        fun lengthOfMessageType(type:Int): Int {
            var midiType:Int = type and 0xF0

            when (type) {
                0xF6, 0xF8, 0xFA, 0xFB, 0xFC, 0xFF, 0xFE -> return 1
                0xF1, 0xF3 -> return 2
                0xF2 -> return 3
            }

            when (midiType) {
                0xC0, 0xD0 -> return 2
                0x80, 0x90, 0xA0, 0xB0, 0xE0 -> return 3
            }
            return 0
        }
    }

}
