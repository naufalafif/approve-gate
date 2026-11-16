package id.naufal.approvegate

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.util.Base64
import androidx.core.app.NotificationCompat
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

/** Keeps one streaming connection to the relay and turns each request into a notification. */
class RelayService : Service() {
    @Volatile private var running = true
    @Volatile private var conn: HttpURLConnection? = null
    private val seen = HashSet<String>()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        channels(this)
        val p = Gate.pairing(this)
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(this, CH_SERVICE)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentTitle("Ready for approvals")
            .setContentText("Listening for ${p?.mac ?: "your Mac"}")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        thread(name = "relay") { loop() }
    }

    override fun onDestroy() {
        running = false
        conn?.disconnect()
        super.onDestroy()
    }

    private fun loop() {
        var backoff = 1000L
        while (running) {
            val p = Gate.pairing(this) ?: break
            try {
                val since = Gate.lastId(this) ?: (System.currentTimeMillis() / 1000 - 30).toString()
                val c = URL("${p.server}/${p.req}/json?since=$since").openConnection() as HttpURLConnection
                c.connectTimeout = 15_000
                c.readTimeout = 90_000 // the relay sends a keepalive every 45 s
                conn = c
                BufferedReader(InputStreamReader(c.inputStream)).use { r ->
                    backoff = 1000L
                    while (running) {
                        val line = r.readLine() ?: break
                        handle(p, line)
                    }
                }
            } catch (e: Exception) {
                if (!running) break
            }
            Thread.sleep(backoff)
            backoff = minOf(backoff * 2, 30_000L)
        }
        stopSelf()
    }

    private fun handle(p: Gate.Pairing, line: String) {
        val ev = runCatching { JSONObject(line) }.getOrNull() ?: return
        if (ev.optString("event") != "message") return
        Gate.setLastId(this, ev.getString("id"))
        val plain = Gate.open(p.key, ev.optString("message")) ?: return
        val msg = runCatching { JSONObject(String(plain)) }.getOrNull() ?: return
        val id = msg.optString("id")
        when (msg.optString("type")) {
            "request" -> {
                if (msg.optLong("expiresAt") * 1000 < System.currentTimeMillis() || !seen.add(id)) return
                showRequest(this, msg, plain)
            }
            "cancel" -> {
                getSystemService(NotificationManager::class.java).cancel(notifId(id))
                Gate.cancelListeners.forEach { it(id) }
            }
            "paired" -> Gate.addHistory(this, "Paired with ${msg.optString("mac")}")
        }
    }

    companion object {
        const val CH_SERVICE = "service"
        const val CH_REQUEST = "requests"

        fun notifId(id: String) = 1000 + (id.hashCode() and 0x7fffffff) % 100000

        fun start(ctx: Context) {
            if (Gate.pairing(ctx) != null) ctx.startForegroundService(Intent(ctx, RelayService::class.java))
        }

        fun channels(ctx: Context) {
            val nm = ctx.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(NotificationChannel(CH_SERVICE, "Connection", NotificationManager.IMPORTANCE_MIN))
            nm.createNotificationChannel(NotificationChannel(CH_REQUEST, "Approval requests", NotificationManager.IMPORTANCE_HIGH).apply {
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                enableVibration(true)
            })
        }

        fun showRequest(ctx: Context, req: JSONObject, plain: ByteArray) {
            val id = req.getString("id")
            val intent = Intent(ctx, ApproveActivity::class.java)
                .putExtra("plain", Base64.encodeToString(plain, Base64.NO_WRAP))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val pi = PendingIntent.getActivity(ctx, notifId(id), intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val prod = req.optBoolean("production")
            val title = (if (prod) "PRODUCTION · " else "") + "Approve ${req.optString("cli")}?"
            // No command or reason here: Android may show notification text on the lock screen
            // whatever the app asks, and commands can hold secrets. They show after unlock.
            val body = buildString {
                if (req.optString("target").isNotEmpty()) append("Target: ").append(req.optString("target")).append("\n")
                append("From: ").append(req.optString("caller")).append("\nTap to review the command.")
            }
            val timeout = req.optLong("expiresAt") * 1000 - System.currentTimeMillis()
            val pub = NotificationCompat.Builder(ctx, CH_REQUEST).setSmallIcon(R.drawable.ic_stat)
                .setContentTitle("Approval request").setContentText("Unlock to see what is being approved").build()
            val n = NotificationCompat.Builder(ctx, CH_REQUEST)
                .setSmallIcon(R.drawable.ic_stat)
                .setColor(if (prod) 0xFFC62828.toInt() else 0xFF6B3FD4.toInt())
                .setContentTitle(title)
                .setContentText("Tap to review the command")
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setContentIntent(pi)
                .setFullScreenIntent(pi, true)
                .setAutoCancel(true)
                .setTimeoutAfter(maxOf(timeout, 1000))
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setPublicVersion(pub)
                .build()
            ctx.getSystemService(NotificationManager::class.java).notify(notifId(id), n)
        }
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) RelayService.start(context)
    }
}
