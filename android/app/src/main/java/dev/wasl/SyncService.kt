package dev.wasl

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.View
import android.view.WindowManager
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import java.net.Inet6Address
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.concurrent.thread

class SyncService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private val http = OkHttpClient.Builder().pingInterval(20, TimeUnit.SECONDS).build()
    private lateinit var frames: Frames
    private lateinit var clipboard: ClipboardManager
    private lateinit var nsd: NsdManager

    private var socket: WebSocket? = null
    private var onLan = false
    private var lanUrl: String? = null
    private var lastText: String? = null // last text sent or received, stops echo loops
    private var discovery: NsdManager.DiscoveryListener? = null
    private var logcat: Process? = null

    override fun onBind(intent: Intent?) = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(1, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        val key = Prefs.key(this) ?: return START_NOT_STICKY.also { stopSelf() }
        frames = Frames(key)
        if (discovery == null) {
            clipboard = getSystemService(ClipboardManager::class.java)
            nsd = getSystemService(NsdManager::class.java)
            clipboard.addPrimaryClipChangedListener(::onClipChanged)
            discover()
            watchClipboardDenials()
        }
        connect()
        return START_STICKY
    }

    override fun onDestroy() {
        discovery?.let { nsd.stopServiceDiscovery(it) }
        logcat?.destroy()
        socket?.cancel()
        socket = null
        main.removeCallbacksAndMessages(null)
    }

    // ---- Connection: LAN when the Mac is visible, else the relay ----

    private fun connect() {
        socket?.cancel()
        onLan = lanUrl != null
        val url = lanUrl ?: Prefs.relayUrl(this)?.let { base ->
            val token = URLEncoder.encode(Prefs.relayToken(this), "UTF-8")
            "${base.trimEnd('/')}/ws?room=${frames.room}&token=$token"
        } ?: return
        socket = http.newWebSocket(Request.Builder().url(url).build(), object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                val plain = frames.open(bytes.toByteArray()) ?: return webSocket.cancel()
                main.post { handle(JSONObject(String(plain))) }
            }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(1000, null) }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = retry(webSocket)
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = retry(webSocket)
        })
    }

    private fun retry(ws: WebSocket) {
        main.postDelayed({ if (socket === ws) connect() }, 3000)
    }

    private fun discover() {
        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) {
                @Suppress("DEPRECATION") // registerServiceInfoCallback is API 34+
                nsd.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onServiceResolved(r: NsdServiceInfo) {
                        val host = r.host ?: return
                        // ponytail: first Mac found wins; filter by service name once multiple Macs per LAN matter.
                        val addr = if (host is Inet6Address) "[${host.hostAddress?.substringBefore('%')}]" else host.hostAddress
                        main.post {
                            lanUrl = "ws://$addr:${r.port}"
                            if (!onLan) connect()
                        }
                    }
                    override fun onResolveFailed(info: NsdServiceInfo, code: Int) {}
                })
            }
            override fun onServiceLost(info: NsdServiceInfo) { main.post { lanUrl = null } }
            override fun onDiscoveryStarted(type: String) {}
            override fun onDiscoveryStopped(type: String) {}
            override fun onStartDiscoveryFailed(type: String, code: Int) {}
            override fun onStopDiscoveryFailed(type: String, code: Int) {}
        }
        nsd.discoverServices("_wasl._tcp", NsdManager.PROTOCOL_DNS_SD, listener)
        discovery = listener
    }

    // ---- Messages ----

    private fun handle(msg: JSONObject) {
        when (msg.optString("t")) {
            "clip" -> {
                val text = msg.getString("text")
                lastText = text
                clipboard.setPrimaryClip(ClipData.newPlainText("wasl", text)) // writing works in background
            }
        }
    }

    private fun send(msg: JSONObject) {
        socket?.send(frames.seal(msg.toString().toByteArray()).toByteString())
    }

    // ---- Clipboard ----

    private fun onClipChanged() {
        val clip = runCatching { clipboard.primaryClip }.getOrNull() ?: return
        if (clip.description.extras?.getBoolean(ClipDescription.EXTRA_IS_SENSITIVE) == true) return
        val text = clip.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(this)?.toString() ?: return
        if (text == lastText) return
        lastText = text
        send(JSONObject().put("t", "clip").put("text", text))
    }

    /**
     * Android 10+ only lets the focused app read the clipboard. ClipboardService logs every denial,
     * so (with READ_LOGS) we watch for ours, then add a 1px overlay to take focus and read it.
     * Same trick as KDE Connect. On Android 13+ the system asks once per service start to allow log access.
     */
    private fun watchClipboardDenials() {
        val needle = "Denying clipboard access to $packageName"
        thread(isDaemon = true) {
            val p = runCatching {
                Runtime.getRuntime().exec(arrayOf("logcat", "-T", "1", "ClipboardService:E", "*:S"))
            }.getOrNull() ?: return@thread
            logcat = p
            p.inputStream.bufferedReader().forEachLine { if (needle in it) main.post(::readWithFocus) }
        }
    }

    private var grabber: View? = null

    private fun readWithFocus() {
        if (grabber != null) return
        val wm = getSystemService(WindowManager::class.java)
        val v = object : View(this) {
            override fun onWindowFocusChanged(hasFocus: Boolean) {
                if (hasFocus) { onClipChanged(); remove() }
            }
            fun remove() {
                if (grabber === this) { grabber = null; wm.removeView(this) }
            }
        }
        val lp = WindowManager.LayoutParams(
            1, 1, WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL, PixelFormat.TRANSLUCENT,
        )
        if (runCatching { wm.addView(v, lp) }.isFailure) return // overlay permission missing
        grabber = v
        main.postDelayed({ v.remove() }, 1000) // never got focus
    }

    private fun notification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel("sync", "Sync", NotificationManager.IMPORTANCE_MIN))
        return Notification.Builder(this, "sync")
            .setSmallIcon(android.R.drawable.ic_menu_share)
            .setContentTitle("Wasl is syncing")
            .build()
    }
}

/** AES-256-GCM frames: nonce(12) || ciphertext || tag(16). Matches CryptoKit's SealedBox.combined. */
class Frames(key: ByteArray) {
    private val spec = SecretKeySpec(key, "AES")
    private val rng = SecureRandom()

    val room: String = MessageDigest.getInstance("SHA-256")
        .digest("wasl-room".toByteArray() + key)
        .joinToString("") { "%02x".format(it) }.take(32)

    fun seal(plain: ByteArray): ByteArray {
        val nonce = ByteArray(12).also(rng::nextBytes)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, spec, GCMParameterSpec(128, nonce))
        return nonce + c.doFinal(plain)
    }

    fun open(frame: ByteArray): ByteArray? = runCatching {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, spec, GCMParameterSpec(128, frame, 0, 12))
        c.doFinal(frame, 12, frame.size - 12)
    }.getOrNull()
}

object Prefs {
    private fun p(s: Service) = s.getSharedPreferences("wasl", Context.MODE_PRIVATE)
    fun key(s: Service): ByteArray? = p(s).getString("key", null)?.let { decodeKey(it) }
    fun relayUrl(s: Service): String? = p(s).getString("relayUrl", null)?.takeIf { it.isNotBlank() }
    fun relayToken(s: Service): String = p(s).getString("relayToken", "")!!

    fun decodeKey(b64: String): ByteArray? =
        runCatching { Base64.decode(b64.trim(), Base64.DEFAULT) }.getOrNull()?.takeIf { it.size == 32 }
}
