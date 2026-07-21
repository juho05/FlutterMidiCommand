package com.invisiblewrench.fluttermidicommand

import android.Manifest
import android.app.Activity
import android.app.Application
import android.bluetooth.*
import android.bluetooth.BluetoothGatt.*
import android.bluetooth.BluetoothProfile.*
import android.bluetooth.le.*
import android.content.*
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.media.midi.*
import android.os.*
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.*
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** FlutterMidiCommandPlugin */
class FlutterMidiCommandPlugin : FlutterPlugin, ActivityAware, MethodCallHandler, PluginRegistry.RequestPermissionsResultListener {

  lateinit var context: Context
  private var activity: Activity? = null
  lateinit var messenger: BinaryMessenger

  private lateinit var midiManager: MidiManager
  private lateinit var handler: Handler

  private var isSupported: Boolean = false

  private var connectedDevices = mutableMapOf<String, ConnectedDevice>()

  lateinit var rxChannel: EventChannel
  lateinit var setupChannel: EventChannel
  lateinit var setupStreamHandler: FMCStreamHandler
  lateinit var bluetoothStateChannel: EventChannel
  lateinit var bluetoothStateHandler: FMCStreamHandler
  lateinit var rxStreamHandler: FMCStreamHandler
  lateinit var disconnectChannel: EventChannel
  lateinit var disconnectStreamHandler: FMCStreamHandler
  var bluetoothState: String = "unknown"
    set(value) {
      bluetoothStateHandler.send(value)
      field = value
    }

  var bluetoothAdapter: BluetoothAdapter? = null
  var bluetoothScanner: BluetoothLeScanner? = null

  private val PERMISSIONS_REQUEST_ACCESS_LOCATION = 95453 // arbitrary
  var discoveredDevices = mutableSetOf<BluetoothDevice>()
  var ongoingConnections = mutableMapOf<String, Result>()

  var blManager:BluetoothManager? = null

  // Shared with the other backends, see platform-matching.md.
  private val connectTimeoutMs = 15000L
  private val reconcileIntervalMs = 5000L
  private val reconcileDebounceMs = 1000L

  private val midiServiceUuid = ParcelUuid.fromString("03B80E5A-EDE8-4B33-A751-6CE34EC4C700")

  /// Whether the Dart side currently wants a scan. The adapter going off stops
  /// the scanner while a scan is still wanted, so the scanner being idle is not
  /// the same as "no scan wanted".
  private var scanRequested = false
  private var connectTimeouts = mutableMapOf<String, Runnable>()
  private var lastReconcile = 0L
  private var reconcileTimerRunning = false
  private var broadcastReceiverRegistered = false
  private var deviceCallbackRegistered = false

  /// Device type of each in-flight connect, so an attempt torn down before it
  /// produced a ConnectedDevice can still report a typed disconnect.
  private var ongoingConnectionTypes = mutableMapOf<String, String>()

  // #region Lifetime functions
  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    messenger = binding.binaryMessenger
    context = binding.applicationContext
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    if (lifecycleCallbacksRegistered) {
      (context.applicationContext as? Application)?.unregisterActivityLifecycleCallbacks(activityLifecycleCallbacks)
      lifecycleCallbacksRegistered = false
    }
    // Unregistering lives here rather than in teardown(), which has to leave the
    // plugin reusable.
    teardown()
    if (deviceCallbackRegistered) {
      midiManager.unregisterDeviceCallback(deviceConnectionCallback)
      deviceCallbackRegistered = false
    }
    if (broadcastReceiverRegistered) {
      try {
        context.unregisterReceiver(broadcastReceiver)
      } catch (e: Exception) {
        // Already unregistered; nothing to do.
      }
      broadcastReceiverRegistered = false
    }
    teardownChannels()
  }

  override fun onAttachedToActivity(p0: ActivityPluginBinding) {
    print("onAttachedToActivity")
    // TODO: your plugin is now attached to an Activity
    activity = p0.activity
    p0.addRequestPermissionsResultListener(this)
    setup()
  }

  override fun onDetachedFromActivityForConfigChanges() {
    print("onDetachedFromActivityForConfigChanges")
    // TODO: the Activity your plugin was attached to was
// destroyed to change configuration.
// This call will be followed by onReattachedToActivityForConfigChanges().
  }

  override fun onReattachedToActivityForConfigChanges(p0: ActivityPluginBinding) {
    // TODO: your plugin is now attached to a new Activity
    p0.addRequestPermissionsResultListener(this)

// after a configuration change.
    print("onReattachedToActivityForConfigChanges")
  }

  override fun onDetachedFromActivity() { // TODO: your plugin is no longer associated with an Activity.
// Clean up references.
    print("onDetachedFromActivity")
    activity = null
  }

  // #endregion

  fun setup() {
    print("setup")

    isSupported =
      context.packageManager.hasSystemFeature(PackageManager.FEATURE_MIDI) &&
      context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)

    val channel = MethodChannel(messenger, "plugins.invisiblewrench.com/flutter_midi_command")
    channel.setMethodCallHandler(this)

    if (!isSupported) {
      return
    }

    if (!::handler.isInitialized) {
      handler = Handler(context.mainLooper)
    }
    if (!::midiManager.isInitialized) {
      midiManager = context.getSystemService(Context.MIDI_SERVICE) as MidiManager
    }
    if (!deviceCallbackRegistered) {
      midiManager.registerDeviceCallback(deviceConnectionCallback, handler)
      deviceCallbackRegistered = true
    }

    rxStreamHandler = FMCStreamHandler(handler)
    rxChannel = EventChannel(messenger, "plugins.invisiblewrench.com/flutter_midi_command/rx_channel")
    rxChannel.setStreamHandler(rxStreamHandler)
    VirtualDeviceService.rxStreamHandler = rxStreamHandler

    setupStreamHandler = FMCStreamHandler(handler)
    setupChannel = EventChannel(messenger, "plugins.invisiblewrench.com/flutter_midi_command/setup_channel")
    setupChannel.setStreamHandler( setupStreamHandler )

    bluetoothStateHandler = FMCStreamHandler(handler)
    bluetoothStateChannel = EventChannel(messenger, "plugins.invisiblewrench.com/flutter_midi_command/bluetooth_central_state")
    bluetoothStateChannel.setStreamHandler( bluetoothStateHandler )

    disconnectStreamHandler = FMCStreamHandler(handler)
    disconnectChannel = EventChannel(messenger, "plugins.invisiblewrench.com/flutter_midi_command/disconnect_channel")
    disconnectChannel.setStreamHandler( disconnectStreamHandler )

    // Reconcile connected devices whenever the app returns to the foreground.
    // While the process is backgrounded/suspended the one-shot onDeviceRemoved
    // callback may never be delivered (or replayed on resume), which would leave
    // a stale "connected" device behind. Diffing on resume guarantees a
    // disconnect event is emitted for anything that vanished while we were away.
    if (!lifecycleCallbacksRegistered) {
      (context.applicationContext as? Application)?.registerActivityLifecycleCallbacks(activityLifecycleCallbacks)
      lifecycleCallbacksRegistered = true
    }
  }

  /// Diffs the currently connected devices against the devices the system still
  /// reports as present, emitting a disconnect for any that have disappeared.
  /// midiManager.devices contains BLE MIDI devices (keyed by their bluetooth
  /// address) as well as native/USB devices, matching the id scheme used as keys
  /// in [connectedDevices].
  private fun reconcileConnectedDevices() {
    if (!isSupported || !::midiManager.isInitialized) return

    val presentIds = midiManager.devices.map { Device.deviceIdForInfo(it) }.toSet()
    connectedDevices.keys.filter { !presentIds.contains(it) }.forEach { id ->
      Log.d("FlutterMIDICommand", "reconcile: device $id no longer present, disconnecting")
      removeDevice(id, "Device disconnected")
    }
  }

  /// Debounced reconcile for the scan-driven entry points (the repeating timer
  /// and every scan result), so discovery bursts coalesce into one diff.
  private fun triggerReconcile() {
    val now = SystemClock.uptimeMillis()
    if (now - lastReconcile < reconcileDebounceMs) return
    lastReconcile = now
    reconcileConnectedDevices()
  }

  private val reconcileRunnable = object : Runnable {
    override fun run() {
      triggerReconcile()
      if (reconcileTimerRunning) handler.postDelayed(this, reconcileIntervalMs)
    }
  }

  private fun startReconcileTimer() {
    if (reconcileTimerRunning) return
    reconcileTimerRunning = true
    handler.postDelayed(reconcileRunnable, reconcileIntervalMs)
  }

  private fun stopReconcileTimer() {
    reconcileTimerRunning = false
    handler.removeCallbacks(reconcileRunnable)
  }

  /// The single removal path. Idempotent: whichever trigger fires first (explicit
  /// disconnect, onDeviceRemoved, reconcile, adapter off, teardown) removes the
  /// entry and emits, later ones find it gone. Explicit and unexpected removals
  /// are indistinguishable to the client.
  private fun removeDevice(deviceId: String, error: String?): Boolean {
    val device = connectedDevices.remove(deviceId)
    if (device == null) {
      // Nothing connected under this id, but an attempt may still be in flight -
      // a removal that tears one down presents as a disconnect, exactly as the
      // path below does, so it must not resolve silently.
      if (ongoingConnections.containsKey(deviceId)) {
        failConnect(deviceId, error ?: "Device disconnected", emitDisconnect = true)
      } else {
        cancelConnectTimeout(deviceId)
        ongoingConnectionTypes.remove(deviceId)
      }
      return false
    }

    cancelConnectTimeout(deviceId)
    ongoingConnectionTypes.remove(deviceId)
    // No connectionFailed: close() below emits deviceDisconnected, which is what
    // darwin sends when a removal tears down an attempt that was under way.
    ongoingConnections.remove(deviceId)?.also {
      it.error("ERROR", error ?: "Device disconnected", deviceId)
    }

    val wasBluetooth = device.isBluetooth
    // close() tears down the (possibly stale) resources and emits both the
    // deviceDisconnected setup event and the disconnect stream event.
    device.close()
    if (wasBluetooth) refreshDiscoveredAfterBLEDisconnect(deviceId)
    return true
  }

  /// Drops a removed BLE device from the discovered set so it can be reported as
  /// appearing again. No scan restart as on darwin: Android scans with
  /// CALLBACK_TYPE_ALL_MATCHES and does not de-duplicate advertisements, so a
  /// device that is still present re-enters the set on its next advertisement,
  /// while one that is really gone stops advertising and stays absent.
  private fun refreshDiscoveredAfterBLEDisconnect(deviceId: String) {
    discoveredDevices.removeIf { it.address == deviceId }
  }

  private var lifecycleCallbacksRegistered = false

  private val activityLifecycleCallbacks = object : Application.ActivityLifecycleCallbacks {
    override fun onActivityResumed(activity: Activity) {
      reconcileConnectedDevices()
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
    override fun onActivityStarted(activity: Activity) {}
    override fun onActivityPaused(activity: Activity) {}
    override fun onActivityStopped(activity: Activity) {}
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
    override fun onActivityDestroyed(activity: Activity) {}
  }


  override fun onMethodCall(call: MethodCall, result: Result): Unit {
//    Log.d("FlutterMIDICommand","call method ${call.method}")

    if (!isSupported) {
      result.error("ERROR", "MIDI not supported", null)
      return
    }

    when (call.method) {
      "sendData" -> {
        var args : Map<String,Any>? = call.arguments()
        sendData(args?.get("data") as ByteArray, args["timestamp"] as? Long, args["deviceId"]?.toString())
        result.success(null)
      }
      "getDevices" -> {
        // Reconcile first so a device that disappeared while we were not
        // scanning is never reported as still connected.
        reconcileConnectedDevices()
        result.success(listOfDevices())
      }

      "bluetoothState" -> {
        result.success(bluetoothState)
      }

      "startBluetoothCentral" -> {
        if (blManager != null && bluetoothAdapter != null && bluetoothScanner != null) {
          result.success(null)
          return
        }
        val errorMsg = tryToInitBT()
        if (errorMsg != null) {
          result.error("ERROR", errorMsg, null)
        } else {
          result.success(null)
        }
      }
      "scanForDevices" -> {
        val errorMsg = startScanningLeDevices()
        if (errorMsg != null) {
          result.error("ERROR", errorMsg, null)
        } else {
          result.success(null)
        }
      }
      "stopScanForDevices" -> {
        stopScanningLeDevices()
        result.success(null)
      }
      "connectToDevice" -> {
        var args = call.arguments<Map<String, Any>>()
        var device = (args?.get("device") as Map<String, Any>)
        var deviceId = device["id"].toString()
        if (connectedDevices[deviceId] != null) {
          result.error("ERROR", "Device already connected", deviceId)
          return
        }
        if (ongoingConnections[deviceId] != null) {
          result.error("ERROR", "Connection already in progress", deviceId)
          return
        }
        ongoingConnections[deviceId] = result
        ongoingConnectionTypes[deviceId] = device["type"].toString()
        val errorMsg = connectToDevice(deviceId, device["type"].toString())
        if (errorMsg != null) {
          failConnect(deviceId, errorMsg)
        }
      }
      "disconnectDevice" -> {
        var args = call.arguments<Map<String, Any>>()
        args?.get("id")?.let { disconnectDevice(it.toString()) }
        result.success(null)
      }
      "teardown" -> {
        teardown()
        result.success(null)
      }

      "addVirtualDevice" -> {
        startVirtualService()
        result.success(null)
      }

      "removeVirtualDevice" -> {
        stopVirtualService()
        result.success(null)
      }

      "isNetworkSessionEnabled" -> {
        result.success(false)
      }

      "enableNetworkSession" -> {
        result.success(null)
      }

      else -> {
        result.notImplemented()
      }
    }
  }

  fun startVirtualService() {
    val comp = ComponentName(context, "com.invisiblewrench.fluttermidicommand.VirtualDeviceService")
    val pm = context.packageManager
    pm.setComponentEnabledSetting(comp, PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.SYNCHRONOUS or PackageManager.DONT_KILL_APP)

  }

  private fun teardownChannels() {
    // Teardown channels
  }

  fun stopVirtualService() {
    val comp = ComponentName(context, "com.invisiblewrench.fluttermidicommand.VirtualDeviceService")
    val pm = context.packageManager
    pm.setComponentEnabledSetting(comp, PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)

  }

  fun appName() : String {
    val pm: PackageManager = context.getPackageManager()
    val info: PackageInfo = pm.getPackageInfo(context.getPackageName(), 0)
    return info.applicationInfo?.loadLabel(pm).toString()
  }

  private fun tryToInitBT() : String? {
    Log.d("FlutterMIDICommand", "tryToInitBT")

    if (Build.VERSION.SDK_INT >= 31 && (context.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED ||
              context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED)) {

      bluetoothState = "unknown";

      if (activity != null) {
        val activity = activity!!
//        if (activity.shouldShowRequestPermissionRationale(Manifest.permission.BLUETOOTH_SCAN) || activity.shouldShowRequestPermissionRationale(Manifest.permission.BLUETOOTH_CONNECT)) {
//          Log.d("FlutterMIDICommand", "Show rationale for Bluetooth")
//          bluetoothState = "unauthorized"
//        } else {
          activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT), PERMISSIONS_REQUEST_ACCESS_LOCATION)
//        }
      }

    } else
      if (Build.VERSION.SDK_INT < 31 && (context.checkSelfPermission(Manifest.permission.BLUETOOTH_ADMIN) != PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED)) {

      bluetoothState = "unknown";

      if (activity != null) {
        var activity = activity!!
//        if (activity.shouldShowRequestPermissionRationale(Manifest.permission.BLUETOOTH_ADMIN) || activity.shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_FINE_LOCATION)) {
//          Log.d("FlutterMIDICommand", "Show rationale for Location")
//          bluetoothState = "unauthorized"
//        } else {
          activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_ADMIN, Manifest.permission.ACCESS_FINE_LOCATION), PERMISSIONS_REQUEST_ACCESS_LOCATION)

//        }
      }
    } else {
      Log.d("FlutterMIDICommand", "Already permitted")

      blManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager

      bluetoothAdapter = blManager!!.adapter
      if (bluetoothAdapter != null) {
        bluetoothState = if (bluetoothAdapter!!.isEnabled) "poweredOn" else "poweredOff";

        // Listen for changes in Bluetooth state. Registered as soon as the
        // adapter exists, not only when a scanner is available: there is no
        // scanner while the adapter is off, and without the receiver the adapter
        // coming back on would never be observed.
        if (!broadcastReceiverRegistered) {
          context.registerReceiver(broadcastReceiver, IntentFilter().apply {
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED);
            addAction( BluetoothDevice.ACTION_BOND_STATE_CHANGED);
          })
          broadcastReceiverRegistered = true
        }

        bluetoothScanner = bluetoothAdapter!!.bluetoothLeScanner
        // A missing scanner is only a failure while the adapter is on. With it
        // off the state is carried by bluetoothState, and STATE_ON picks the
        // scanner up again.
        if (bluetoothScanner == null && bluetoothAdapter!!.isEnabled) {
          Log.d("FlutterMIDICommand", "bluetoothScanner is null")
          return "bluetoothNotAvailable"
        }
      } else {
        bluetoothState = "unsupported";
        Log.d("FlutterMIDICommand", "bluetoothAdapter is null")
      }
    }
    return null
  }

  private val broadcastReceiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
      val action = intent.action

      if (action.equals(BluetoothAdapter.ACTION_STATE_CHANGED)) {
        val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)

        when (state) {
          BluetoothAdapter.STATE_OFF -> {
            Log.d("FlutterMIDICommand", "BT is now off")
            bluetoothState = "poweredOff";
            bluetoothScanner = null
            reapBluetoothState()
          }

          BluetoothAdapter.STATE_TURNING_OFF -> {
            Log.d("FlutterMIDICommand", "BT is now turning off")
          }

          BluetoothAdapter.STATE_ON -> {
            bluetoothState = "poweredOn";
            Log.d("FlutterMIDICommand", "BT is now on")
            // The scanner obtained while the adapter was off is null/stale.
            bluetoothScanner = bluetoothAdapter?.bluetoothLeScanner
            // reapBluetoothState leaves scanRequested set precisely so a scan the
            // Dart side asked for survives an adapter off/on cycle.
            if (scanRequested) {
              seedSystemHeldDevices()
              startReconcileTimer()
              resumeScanIfNeeded()
            }
          }
        }
      } else

      if (action.equals(BluetoothDevice.ACTION_BOND_STATE_CHANGED)) {
        val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
        val previousBondState = intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, -1)
        val bondState = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1)
        val bondTransition = "${previousBondState.toBondStateDescription()} to " + bondState.toBondStateDescription()
        // Logged only: the setup stream carries the shared vocabulary, not
        // platform-native bond strings.
        Log.d("Bond state change", "${device?.address} bond state changed | $bondTransition")
      }
    }

    private fun Int.toBondStateDescription() = when(this) {
      BluetoothDevice.BOND_BONDED -> "BONDED"
      BluetoothDevice.BOND_BONDING -> "BONDING"
      BluetoothDevice.BOND_NONE -> "NOT BONDED"
      else -> "ERROR: $this"
    }
  }

  /// The adapter leaving the on state invalidates every BLE peripheral, so all
  /// BLE state is reaped event-driven rather than waiting for a reconcile.
  private fun reapBluetoothState() {
    stopReconcileTimer()
    connectedDevices.filterValues { it.isBluetooth }.keys.toList().forEach { id ->
      removeDevice(id, "Bluetooth unavailable")
    }
    if (discoveredDevices.isNotEmpty()) {
      discoveredDevices.clear()
      setupStreamHandler.send("deviceDisappeared")
    }
  }

  /// Stops first so a re-scan or a resume after the adapter came back on cannot
  /// hit SCAN_FAILED_ALREADY_STARTED.
  private fun startLeScan() {
    bluetoothScanner?.stopScan(bleScanner)
    val filter = ScanFilter.Builder().setServiceUuid(midiServiceUuid).build()
    val settings = ScanSettings.Builder().build()
    bluetoothScanner?.startScan(listOf(filter), settings, bleScanner)
  }

  private fun startScanningLeDevices() : String? {
    if (bluetoothScanner == null) {
      val errMsg = tryToInitBT()
      errMsg?.let {
        return it
      }
    }

    if (bluetoothScanner == null || bluetoothAdapter?.isEnabled != true) {
      Log.d("FlutterMIDICommand", "Can't scan, bluetooth not available")
      return "bluetoothNotAvailable"
    }

    Log.d("FlutterMIDICommand", "Start BLE Scan")

    // Seed peripherals the system already holds, so a device connected by
    // another app (or before this process started) still surfaces.
    seedSystemHeldDevices()

    scanRequested = true
    startReconcileTimer()
    startLeScan()
    return null
  }

  /// Connected GATT devices the MIDI manager also knows about. getConnectedDevices
  /// cannot filter by service, so the MidiDeviceInfo cross-check stands in for
  /// darwin's retrieveConnectedPeripherals(withServices:) - without it any
  /// connected non-MIDI peripheral would be listed as a MIDI device.
  private fun seedSystemHeldDevices() {
    val midiAddresses = midiManager.devices.mapNotNull { Device.bluetoothDeviceForInfo(it)?.address }.toSet()
    blManager?.getConnectedDevices(GATT_SERVER)
      ?.filter { midiAddresses.contains(it.address) }
      ?.forEach {
        if (discoveredDevices.add(it)) {
          Log.d("FlutterMIDICommand", "seed system held device ${it.address}")
          setupStreamHandler.send("deviceAppeared")
        }
      }
  }

  private fun stopScanningLeDevices() {
    Log.d("FlutterMIDICommand", "Stop BLE Scan")
    scanRequested = false
    stopReconcileTimer()
    bluetoothScanner?.stopScan(bleScanner)
    // Prune discovered-but-not-connected entries only; a connected device has to
    // survive so the active session keeps being listed.
    discoveredDevices.removeIf { !connectedDevices.containsKey(it.address) }
  }

//fun onRequestPermissionsResult(p0: Int, p1: Array<(out) String!>, p2: IntArray): Boolean
  override fun onRequestPermissionsResult(
          requestCode: Int,
          permissions: Array<out String>,
          grantResults: IntArray): Boolean {
    Log.d("FlutterMIDICommand", "Permissions code: $requestCode grantResults: $grantResults")

    if (!isSupported) {
      Log.d("FlutterMIDICommand", "MIDI not supported")
      return false;
    }

    if (requestCode != PERMISSIONS_REQUEST_ACCESS_LOCATION) {
      return false;
    }

    if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) {
      // Only finish initialising and report state; scanning starts when asked.
      tryToInitBT()
    } else {
      bluetoothState = "unauthorized"
      Log.d("FlutterMIDICommand", "Perms failed")
    }
    return true;
  }

  private fun connectToDevice(deviceId:String, type:String) : String? {
    Log.d("FlutterMIDICommand", "connect to $type device: $deviceId")

    if (type == "BLE" || type == "bonded") {
      val bleDevice = discoveredDevices.firstOrNull { it.address == deviceId }
        ?: blManager?.getConnectedDevices(GATT_SERVER)?.firstOrNull { it.address == deviceId }
      if (bleDevice == null) {
        // No BluetoothDevice to open, but BluetoothMidiService may already hold
        // the link (device opened by another app, or the discovered set was
        // pruned by stopScanForDevices). There is then no GATT connection left
        // to establish and the MidiDeviceInfo can be opened directly.
        Log.d("FlutterMIDICommand", "No BLE device for $deviceId, trying midiManager")
        return openMidiManagerDevice(deviceId)
      }
      Log.d("FlutterMIDICommand", "Open device")
      // Deliberately keeps scanning, unlike darwin: each stop/start pair spends
      // one of the 5 startScan calls Android allows per 30s, which a few
      // connects in a row would exhaust. Costs some connect latency.
      startConnectTimeout(deviceId)
      midiManager.openBluetoothDevice(bleDevice, deviceOpenedListener(deviceId), handler)
    } else if (type == "native") {
      return openMidiManagerDevice(deviceId)
    } else {
      Log.d("FlutterMIDICommand", "Can't connect to unknown device type $type")
      return "Unknown device type $type"
    }
    return null;
  }

  /// Opens a device the MIDI manager already knows about. Shared by the native
  /// path and the BLE fallback: [Device.deviceIdForInfo] keys a bluetooth-backed
  /// MidiDeviceInfo by its address, so the id the Dart side holds for a BLE
  /// device resolves here too.
  private fun openMidiManagerDevice(deviceId: String) : String? {
    val device = midiManager.devices.firstOrNull { d -> Device.deviceIdForInfo(d) == deviceId }
    if (device == null) {
      Log.d("FlutterMIDICommand", "not found device $deviceId")
      return "Device not found"
    }
    Log.d("FlutterMIDICommand", "open device $device")
    startConnectTimeout(deviceId)
    midiManager.openDevice(device, deviceOpenedListener(deviceId), handler)
    return null
  }

  private fun startConnectTimeout(deviceId: String) {
    cancelConnectTimeout(deviceId)
    val runnable = Runnable {
      connectTimeouts.remove(deviceId)
      Log.d("FlutterMIDICommand", "connect timeout for $deviceId")
      // Exactly one deviceDisconnected either way: via close() when a half-opened
      // device made it into the map, via failConnect when not.
      removeDevice(deviceId, "Connection timed out")
    }
    connectTimeouts[deviceId] = runnable
    handler.postDelayed(runnable, connectTimeoutMs)
  }

  private fun cancelConnectTimeout(deviceId: String) {
    connectTimeouts.remove(deviceId)?.also { handler.removeCallbacks(it) }
  }

  /// Resolves a pending connect successfully, exactly once.
  private fun completeConnectSuccess(deviceId: String) {
    cancelConnectTimeout(deviceId)
    ongoingConnectionTypes.remove(deviceId)
    ongoingConnections.remove(deviceId)?.also {
      setupStreamHandler.send("deviceConnected")
      it.success(null)
    }
  }

  /// Fails a pending connect, exactly once. [emitDisconnect] for the paths that
  /// tear down an attempt already under way (timeout, teardown): those present
  /// as a disconnect, matching darwin, where a pending connect always has a
  /// device entry to remove. Otherwise the attempt never got going and
  /// connectionFailed is the event.
  private fun failConnect(deviceId: String, message: String, emitDisconnect: Boolean = false) {
    cancelConnectTimeout(deviceId)
    val type = ongoingConnectionTypes.remove(deviceId)
    ongoingConnections.remove(deviceId)?.also {
      it.error("ERROR", message, deviceId)
      if (emitDisconnect) {
        setupStreamHandler.send("deviceDisconnected")
        disconnectStreamHandler.send(mapOf("id" to deviceId, "name" to null, "type" to (type ?: "native")))
      } else {
        setupStreamHandler.send("connectionFailed")
      }
    }
  }

  private fun resumeScanIfNeeded() {
    if (!scanRequested || bluetoothScanner == null || bluetoothAdapter?.isEnabled != true) return
    startLeScan()
  }

  private val bleScanner = object : ScanCallback() {
    override fun onScanResult(callbackType: Int, result: ScanResult?) {
      super.onScanResult(callbackType, result)
      Log.d("FlutterMIDICommand", "onScanResult: ${result?.device?.address} - ${result?.device?.name}")
      result?.also {
        if (discoveredDevices.add(it.device)) {
          setupStreamHandler.send("deviceAppeared")
        }
      }
      // A fresh advertisement is the moment a stale connected/discovered pair
      // materializes, so reconcile (debounced against discovery bursts).
      triggerReconcile()
    }

    override fun onScanFailed(errorCode: Int) {
      super.onScanFailed(errorCode)

      var messages = mapOf(
        SCAN_FAILED_ALREADY_STARTED to "Scan already started",
              SCAN_FAILED_APPLICATION_REGISTRATION_FAILED to "Application Registration Failed",
              SCAN_FAILED_FEATURE_UNSUPPORTED to "Future Unsupported",
              SCAN_FAILED_INTERNAL_ERROR to "Internal Error"
//              SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES to "Out of HW Resources",
//              SCAN_FAILED_SCANNING_TOO_FREQUENTLY to "Scanning too frequently"
              )


      Log.d("FlutterMIDICommand", "onScanFailed: $errorCode")
      setupStreamHandler.send("BLE scan failed $errorCode ${messages[errorCode]}")
    }
  }


  /// Disconnects everything and stops scanning, leaving the plugin reusable.
  /// Callback/receiver unregistration happens in onDetachedFromEngine.
  fun teardown() {
    Log.d("FlutterMIDICommand", "teardown")

    // Reachable from onDetachedFromEngine before an Activity ever attached, in
    // which case setup() never ran and there is nothing to tear down.
    if (!isSupported || !::handler.isInitialized) return

    stopVirtualService()
    stopScanningLeDevices()

    connectedDevices.keys.toList().forEach { removeDevice(it, "Device disconnected") }
    // Any connect still in flight has no device entry yet, so fail it explicitly.
    ongoingConnections.keys.toList().forEach { failConnect(it, "Device disconnected", emitDisconnect = true) }
    discoveredDevices.clear()
  }

  fun disconnectDevice(deviceId: String) {
    removeDevice(deviceId, "Device disconnected")
  }

  fun sendData(data: ByteArray, timestamp: Long?, deviceId: String?) {
    if (deviceId != null) {
      if (connectedDevices.containsKey(deviceId)) {
        connectedDevices[deviceId]?.let {
          Log.d("FlutterMIDICommand", "send midi to $it ${it.id}")
          it.send(data, timestamp)
        }
      } else {
        Log.d("FlutterMIDICommand", "no device for id $deviceId")
      }
    }
     else {
      connectedDevices.values.forEach {
        it.send(data, timestamp)
      }
    }
  }

  fun listOfPorts(count: Int) :  List<Map<String, Any>> {
    return (0 until count).map { mapOf("id" to it, "connected" to false) }
  }

  fun listOfDevices() : List<Map<String, Any>> {
    var list = mutableMapOf<String, Map<String, Any>>()


    // Bonded BT devices
    var connectedGattDeviceIds = mutableListOf<String>()
    var connectedGattDevices = blManager?.getConnectedDevices(GATT_SERVER)
    connectedGattDevices?.forEach {
      Log.d("FlutterMIDICommand", "connectedGattDevice ${it.address} type ${it.type} name ${it.name}")
      connectedGattDeviceIds.add(it.address)
    }

  var bondedDeviceIds = mutableListOf<String>()
    var bondedDevices = bluetoothAdapter?.getBondedDevices()
    bondedDevices?.forEach {
      Log.d("FlutterMIDICommand", "add bonded device ${it.address} type ${it.type} name ${it.name}")
      bondedDeviceIds.add(it.address)

      var id = it.address
      if (connectedGattDeviceIds.contains(id)) {
        list[id] = mapOf(
          "name" to it.name,
          "id" to id,
          "type" to "bonded",
          "connected" to if (connectedDevices.contains(it.address)) "true" else "false",///*if (connectedGattDeviceIds.contains(id)) "true" else*/ "false",
          "inputs" to listOf(mapOf("id" to 0, "connected" to false)),
          "outputs" to listOf(mapOf("id" to 0, "connected" to false))
        )
      }
    }

    // Discovered BLE devices
    discoveredDevices.forEach {
      var id = it.address;
      Log.d("FlutterMIDICommand", "add discovered device $ type ${it.type}")

      if (list.contains(id)) {
        Log.d("FlutterMIDICommand", "device already in list $id")
      } else {
        Log.d("FlutterMIDICommand", "add native device $id type ${it.type}")
        list[id] = mapOf(
          "name" to it.name,
          "id" to id,
          "type" to "BLE",
          "connected" to if (connectedDevices.contains(id)) "true" else "false",
          "inputs" to listOf(mapOf("id" to 0, "connected" to false)),
          "outputs" to listOf(mapOf("id" to 0, "connected" to false))
        )
      }
    }

    // Generic MIDI devices
    val devs:Array<MidiDeviceInfo> = midiManager.devices
    devs.forEach {
      var id = Device.deviceIdForInfo(it)
      Log.d("FlutterMIDICommand", "add device from midiManager id $id")

      if (list.contains(id)) {
        Log.d("FlutterMIDICommand", "device already in list $id")
      } else {
        Log.d("FlutterMIDICommand", "add native device $id type ${it.type}")

        // A bluetooth-backed device stays BLE/bonded even when it only shows up
        // here, which is the common case for a connected device once the
        // discovered set has been pruned.
        val type = if (Device.isBluetoothInfo(it)) {
          if (bondedDeviceIds.contains(id)) "bonded" else "BLE"
        } else "native"

        list[id] = mapOf(
          "name" to (it.properties.getString(MidiDeviceInfo.PROPERTY_NAME) ?: "-"),
          "id" to id,
          "type" to type,
          "connected" to if (connectedDevices.contains(id)) "true" else "false",
          "inputs" to listOfPorts(it.inputPortCount),
          "outputs" to listOfPorts(it.outputPortCount)
        )
      }
    }

    Log.d("FlutterMIDICommand", "list $list")

    return list.values.toList()
  }


  /// Per-connect listener so a failed open can be attributed to the id it was
  /// requested for - MidiManager reports failure as a null device, which carries
  /// no identity of its own.
  private fun deviceOpenedListener(deviceId: String) = MidiManager.OnDeviceOpenedListener { opened ->
    Log.d("FlutterMIDICommand", "onDeviceOpened $deviceId")
    if (opened == null) {
      Log.d("FlutterMIDICommand", "Failed to open device $deviceId")
      failConnect(deviceId, "Failed to open device")
      return@OnDeviceOpenedListener
    }

    if (ongoingConnections[deviceId] == null) {
      // The attempt was already resolved (timeout, teardown, adapter off).
      Log.d("FlutterMIDICommand", "Opened device $deviceId is no longer awaited, closing")
      try { opened.close() } catch (e: Exception) { }
      return@OnDeviceOpenedListener
    }

    // The id is the key for reconcile, sendData and disconnectDevice alike, so an
    // entry stored under the requested id while resolving to a different one is
    // unusable: the next reconcile would not find it present and would tear it
    // down, and its disconnect event would carry an id the client cannot match.
    // Fail while there is still a pending result to report it on.
    val openedId = Device.deviceIdForInfo(opened.info)
    if (openedId != deviceId) {
      Log.w("FlutterMIDICommand", "opened device id $openedId differs from requested $deviceId")
      try { opened.close() } catch (e: Exception) { }
      failConnect(deviceId, "Opened device id $openedId does not match requested $deviceId")
      return@OnDeviceOpenedListener
    }

    val device = ConnectedDevice(opened, setupStreamHandler)
    device.disconnectStreamHandler = disconnectStreamHandler
    connectedDevices[deviceId] = device
    device.connectWithStreamHandler(rxStreamHandler,
      onSuccess = {
        Log.d("FlutterMIDICommand", "Opened device id $deviceId")
        completeConnectSuccess(deviceId)
      },
      onFailure = { message -> removeDevice(deviceId, message) })
  }

  private val deviceConnectionCallback = object : MidiManager.DeviceCallback() {

    override fun onDeviceAdded(device: MidiDeviceInfo?) {
      super.onDeviceAdded(device)
      device?.also {
        Log.d("FlutterMIDICommand", "MIDI device added $it")
        this@FlutterMidiCommandPlugin.setupStreamHandler.send("deviceAppeared")
      }
    }

    override fun onDeviceRemoved(device: MidiDeviceInfo?) {
      super.onDeviceRemoved(device)
      device?.also {
        Log.d("FlutterMIDICommand","MIDI device removed $it")
        removeDevice(Device.deviceIdForInfo(it), "Device disconnected")
        this@FlutterMidiCommandPlugin.setupStreamHandler.send("deviceDisappeared")
      }
    }

    override fun onDeviceStatusChanged(status: MidiDeviceStatus?) {
      super.onDeviceStatusChanged(status)
      // Logged only: the setup stream carries the shared vocabulary, not
      // platform-native status strings.
      Log.d("FlutterMIDICommand","MIDI device status changed ${status.toString()}")
    }


  }


}


