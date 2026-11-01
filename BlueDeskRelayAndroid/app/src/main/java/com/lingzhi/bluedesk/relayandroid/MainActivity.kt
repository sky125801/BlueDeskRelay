package com.lingzhi.bluedesk.relayandroid

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.core.content.IntentCompat
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow

class MainActivity : ComponentActivity() {

    private lateinit var snackbarHostState: SnackbarHostState
    private val shareHint = MutableStateFlow<String?>(null)

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            if (hasConnectPermission()) startRelayIfNeeded()
        }

    private val filePicker =
        registerForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
            if (uris.isNotEmpty()) RelayEngine.sendUris(uris)
        }

    private val folderPicker =
        registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
            if (uri != null) {
                runCatching {
                    contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                }
                RelayEngine.sendTree(uri)
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        RelayEngine.init(applicationContext)
        snackbarHostState = SnackbarHostState()

        if (!hasConnectPermission()) {
            permissionLauncher.launch(requiredPermissions())
        } else {
            startRelayIfNeeded()
        }
        handleShare(intent)

        setContent {
            RelayTheme {
                val state by RelayEngine.state.collectAsState()
                val records by RelayEngine.records.collectAsState()
                val transferLimit by RelayEngine.transferLimit.collectAsState()
                var background by remember { mutableStateOf(backgroundEnabled()) }
                val devices by produceState(initialValue = RelayEngine.pairedDevices()) {
                    while (true) {
                        value = RelayEngine.pairedDevices()
                        delay(3000)
                    }
                }

                LaunchedEffect(Unit) {
                    RelayEngine.messages.collect { snackbarHostState.showSnackbar(it) }
                }
                LaunchedEffect(Unit) {
                    shareHint.collect { message ->
                        if (message != null) {
                            snackbarHostState.showSnackbar(message)
                            shareHint.value = null
                        }
                    }
                }

                RelayRoot(
                    state = state,
                    devices = devices,
                    records = records,
                    background = background,
                    transferLimit = transferLimit,
                    snackbarHostState = snackbarHostState,
                    onReconnect = { RelayEngine.reconnect() },
                    onDisconnect = { RelayEngine.disconnect() },
                    onSelectDevice = { RelayEngine.connectTo(it) },
                    onToggleBackground = { enabled ->
                        background = enabled
                        setBackgroundEnabled(enabled)
                        if (enabled) {
                            if (hasConnectPermission()) startRelayIfNeeded()
                            else permissionLauncher.launch(requiredPermissions())
                        }
                    },
                    onSendText = { text -> RelayEngine.sendText(text) },
                    onSendFiles = { filePicker.launch(arrayOf("*/*")) },
                    onSendFolder = { folderPicker.launch(null) }
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShare(intent)
    }

    override fun onResume() {
        super.onResume()
        if (hasConnectPermission()) startRelayIfNeeded()
    }

    /** 其他 App 通过系统分享把文字 / 文件送进来 */
    private fun handleShare(intent: Intent?) {
        if (intent == null) return
        when (intent.action) {
            Intent.ACTION_SEND -> {
                val type = intent.type.orEmpty()
                if (type.startsWith("text/")) {
                    val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)
                    if (!text.isNullOrBlank()) {
                        RelayEngine.sendText(text.toString())
                        shareHint.value = getString(R.string.msg_queued)
                    }
                } else {
                    val uri = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                    if (uri != null) {
                        RelayEngine.sendUris(listOf(uri))
                        shareHint.value = getString(R.string.msg_queued)
                    }
                }
            }

            Intent.ACTION_SEND_MULTIPLE -> {
                val uris = IntentCompat.getParcelableArrayListExtra(
                    intent, Intent.EXTRA_STREAM, Uri::class.java
                )
                if (!uris.isNullOrEmpty()) {
                    RelayEngine.sendUris(uris)
                    shareHint.value = getString(R.string.msg_queued)
                }
            }
        }
    }

    private fun startRelayIfNeeded() {
        if (!hasConnectPermission()) return
        if (backgroundEnabled()) RelayService.start(this) else RelayEngine.start()
    }

    private fun setBackgroundEnabled(enabled: Boolean) {
        prefs().edit().putBoolean(BootReceiver.KEY_BACKGROUND, enabled).apply()
        if (enabled) startRelayIfNeeded() else RelayService.stop(this)
    }

    private fun backgroundEnabled(): Boolean =
        prefs().getBoolean(BootReceiver.KEY_BACKGROUND, true)

    private fun prefs() = getSharedPreferences("relay_prefs", Context.MODE_PRIVATE)

    private fun hasConnectPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return ContextCompat.checkSelfPermission(
            this, Manifest.permission.BLUETOOTH_CONNECT
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requiredPermissions(): Array<String> {
        val list = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            list += Manifest.permission.BLUETOOTH_CONNECT
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            list += Manifest.permission.POST_NOTIFICATIONS
        }
        return list.toTypedArray()
    }
}
