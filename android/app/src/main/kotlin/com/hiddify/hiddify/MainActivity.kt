package com.hiddify.hiddify

import android.content.Intent
import android.Manifest
import android.net.VpnService
import android.os.Build
import android.util.Log
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.lifecycleScope
import com.hiddify.hiddify.bg.ServiceConnection
import com.hiddify.hiddify.bg.ServiceNotification
import com.hiddify.hiddify.constant.Alert
import com.hiddify.hiddify.constant.ServiceMode
import com.hiddify.hiddify.constant.Status
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.LinkedList


class MainActivity : FlutterFragmentActivity(), ServiceConnection.Callback {
    companion object {
        private const val TAG = "ANDROID/MyActivity"
        lateinit var instance: MainActivity
    }

    private val connection = ServiceConnection(this, this)
    private val startLock = Any()
    private var pendingStart: CompletableDeferred<Boolean>? = null

    val logList = LinkedList<String>()
    var logCallback: ((Boolean) -> Unit)? = null
    val serviceStatus = MutableLiveData(Status.Stopped)
    val serviceAlerts = MutableLiveData<ServiceEvent?>(null)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        instance = this
        reconnect()
        flutterEngine.plugins.add(MethodHandler(lifecycleScope))
        flutterEngine.plugins.add(PlatformSettingsHandler())
        flutterEngine.plugins.add(EventHandler())
        flutterEngine.plugins.add(LogHandler())
//        flutterEngine.plugins.add(GroupsChannel(lifecycleScope))
//        flutterEngine.plugins.add(ActiveGroupsChannel(lifecycleScope))
//        flutterEngine.plugins.add(StatsChannel(lifecycleScope))
    }

    fun reconnect() {
        connection.reconnect()
    }

    fun startService() {
        lifecycleScope.launch {
            startServiceAndWait()
        }
    }

    suspend fun startServiceAndWait(): Boolean {
        if (serviceStatus.value == Status.Started) return true

        var shouldStart = false
        val request = synchronized(startLock) {
            pendingStart?.takeIf { it.isActive } ?: CompletableDeferred<Boolean>().also {
                pendingStart = it
                shouldStart = true
            }
        }

        if (shouldStart) {
            withContext(Dispatchers.Main) {
                requestServiceStart()
            }
        }
        return request.await()
    }

    private fun requestServiceStart() {
        if (!hasPendingStart()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !ServiceNotification.checkPermission()) {
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            return
        }
        startService0()
    }

    private fun startService0() {
        lifecycleScope.launch(Dispatchers.IO) {
            try {
                if (!hasPendingStart()) return@launch
                if (Settings.rebuildServiceMode()) {
                    connection.reconnect()
                }
                if (Settings.serviceMode == ServiceMode.VPN) {
                    if (prepare()) {
                        return@launch
                    }
                }
                if (!hasPendingStart()) return@launch
                val intent = Intent(Application.application, Settings.serviceClass())
                withContext(Dispatchers.Main) {
                    ContextCompat.startForegroundService(this@MainActivity, intent)
                }
                Settings.startedByUser = true
            } catch (e: Exception) {
                Log.e(TAG, "failed to start service", e)
                onServiceAlert(Alert.StartService, e.message)
            }
        }
    }

    private suspend fun prepare() = withContext(Dispatchers.Main) {
        try {
            val intent = VpnService.prepare(this@MainActivity)
            if (intent != null) {
                prepareLauncher.launch(intent)
                true
            } else {
                false
            }
        } catch (e: Exception) {
            onServiceAlert(Alert.RequestVPNPermission, e.message)
            true
        }
    }
    private val notificationPermissionLauncher =
        registerForActivityResult(
            ActivityResultContracts.RequestPermission(),
        ) { isGranted ->
            if (!hasPendingStart()) return@registerForActivityResult
            if (Settings.dynamicNotification && !isGranted) {
                onServiceAlert(Alert.RequestNotificationPermission, null)
            } else {
                startService0()
            }
        }

    private val prepareLauncher =
        registerForActivityResult(
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            if (!hasPendingStart()) return@registerForActivityResult
            if (result.resultCode == RESULT_OK) {
                startService0()
            } else {
                onServiceAlert(Alert.RequestVPNPermission, null)
            }
        }

    override fun onServiceStatusChanged(status: Status) {
        serviceStatus.postValue(status)
        if (status == Status.Started) {
            completePendingStart(true)
        }
    }

    override fun onServiceAlert(type: Alert, message: String?) {
        serviceAlerts.postValue(ServiceEvent(Status.Stopped, type, message))
        completePendingStart(false)
    }




    fun cancelPendingStart() {
        completePendingStart(false)
    }

    private fun hasPendingStart(): Boolean = synchronized(startLock) {
        pendingStart?.isActive == true
    }

    private fun completePendingStart(success: Boolean) {
        val request = synchronized(startLock) {
            pendingStart.also { pendingStart = null }
        }
        request?.complete(success)
    }

    override fun onDestroy() {
        cancelPendingStart()
        connection.disconnect()
        super.onDestroy()
    }

}
