package id.naufal.approvegate

import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.util.Base64
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import org.json.JSONObject
import kotlin.concurrent.thread

class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
        RelayService.channels(this)
        RelayService.start(this)
        // A pairing link is used once: not again when Android restores the screen, reopens it from
        // recents, or relaunches it after a crash. Re-pairing by accident replaced the key once.
        val fromHistory = intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0
        if (savedInstanceState == null && !fromHistory) handleLink(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleLink(intent)
    }

    override fun onResume() {
        super.onResume()
        render()
    }

    private fun handleLink(i: Intent?) {
        val u = i?.data ?: return
        setIntent(Intent(this, MainActivity::class.java))
        if (u.scheme == "approvegate" && u.host == "pair") confirmPair(u)
    }

    private fun render() {
        val c = this
        val col = Ui.column(c)
        col.addView(Ui.text(c, "Approve Gate", 28f, bold = true))
        val p = Gate.pairing(c)
        if (p == null) {
            col.addView(Ui.text(c, "Approve commands from your Mac with your fingerprint. Each request shows the command, " +
                "where it runs and who asked, before you scan.", 15f, Ui.MUTED), Ui.lp(c, top = 8))
            val card = Ui.card(c)
            card.addView(Ui.text(c, "Not paired", 17f, bold = true))
            card.addView(Ui.text(c, "On the Mac, run  approve pair  and scan the code it shows.", 15f, Ui.MUTED), Ui.lp(c, top = 4))
            col.addView(card, Ui.lp(c, top = 24))
            Ui.screen(this, col, bottomBar(Ui.button(c, "Scan pairing code", true) { scan() }))
            return
        }

        val batteryOn = !getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)
        val status = Ui.card(c)
        val head = Ui.row(c)
        head.addView(Ui.dot(c, if (batteryOn) Ui.WARN else Ui.OK))
        head.addView(Ui.text(c, if (batteryOn) "Paired, may be late while asleep" else "Paired and ready", 14f, Ui.MUTED, bold = true))
        status.addView(head)
        status.addView(Ui.oneLine(Ui.text(c, p.mac, 20f, bold = true)), Ui.lp(c, top = 8))
        status.addView(Ui.text(c, "Requests from this Mac arrive as notifications. Tap one to review it.", 14f, Ui.MUTED),
            Ui.lp(c, top = 4))
        col.addView(status, Ui.lp(c, top = 24))

        if (batteryOn) {
            val warn = Ui.card(c, Ui.WARN_SURFACE)
            warn.addView(Ui.text(c, "Battery optimisation is on", 15f, bold = true))
            warn.addView(Ui.text(c, "Requests can arrive late while the phone sleeps.", 14f, Ui.MUTED), Ui.lp(c, top = 4))
            warn.addView(Ui.button(c, "Allow in background", true) { askBattery() }, Ui.lp(c, top = 12))
            col.addView(warn, Ui.lp(c, top = 12))
        }

        col.addView(Ui.label(c, "Recent", top = 32))
        val h = Gate.history(c).take(15)
        if (h.isEmpty()) col.addView(Ui.text(c, "Nothing yet.", 15f, Ui.MUTED))
        h.forEachIndexed { i, line ->
            if (i > 0) col.addView(Ui.divider(c))
            col.addView(historyRow(line))
        }

        col.addView(Ui.button(c, "Unpair this phone", Ui.Kind.DANGER_TEXT) {
            AlertDialog.Builder(c).setTitle("Unpair ${p.mac}?")
                .setMessage("The Mac falls back to Touch ID only. The signing key on this phone is deleted.")
                .setPositiveButton("Unpair") { _, _ ->
                    stopService(Intent(c, RelayService::class.java)); Gate.unpair(c); render()
                }.setNegativeButton("Keep", null).show()
        }, Ui.lp(c, top = 24))
        Ui.screen(this, col, bottomBar(Ui.button(c, "Scan a new pairing code", false) { scan() }))
    }

    /** "13 Nov 20:46  Approved: vault version" as a row: coloured dot, what happened, when. */
    private fun historyRow(line: String): android.view.View {
        val c = this
        val parts = line.split("  ", limit = 2)
        val stamp = if (parts.size == 2) parts[0] else ""
        val what = parts.last()
        val color = when {
            what.startsWith("Approved") -> Ui.OK
            what.startsWith("Denied") -> Ui.DANGER
            else -> Ui.PURPLE
        }
        val row = Ui.row(c).apply { setPadding(0, Ui.dp(c, 12), 0, Ui.dp(c, 12)) }
        row.addView(Ui.dot(c, color, 8))
        val texts = android.widget.LinearLayout(c).apply { orientation = android.widget.LinearLayout.VERTICAL }
        texts.addView(Ui.oneLine(Ui.text(c, what, 15f)))
        if (stamp.isNotEmpty()) texts.addView(Ui.text(c, stamp, 13f, Ui.MUTED), Ui.lp(c, top = 2))
        row.addView(texts, Ui.lp(c, weight = 1f))
        return row
    }

    private fun bottomBar(button: android.view.View) = Ui.column(this, top = 12, bottom = 12).apply { addView(button) }

    private fun scan() {
        val opts = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
        GmsBarcodeScanning.getClient(this, opts).startScan()
            .addOnSuccessListener { b ->
                val u = Uri.parse(b.rawValue ?: "")
                if (u.scheme == "approvegate" && u.host == "pair") confirmPair(u)
                else AlertDialog.Builder(this).setMessage("That is not an Approve Gate pairing code.").setPositiveButton("OK", null).show()
            }
    }

    private fun confirmPair(u: Uri) {
        val mac = u.getQueryParameter("m") ?: "Mac"
        val existing = Gate.pairing(this)
        val msg = "Approvals from $mac will be signed by a key on this phone that only your fingerprint unlocks." +
            (existing?.let { "\n\nThis replaces the pairing with ${it.mac}." } ?: "")
        AlertDialog.Builder(this).setTitle("Pair with $mac?").setMessage(msg)
            .setPositiveButton("Pair") { _, _ -> pair(u, mac) }.setNegativeButton("Cancel", null).show()
    }

    private fun pair(u: Uri, mac: String) {
        if (BiometricManager.from(this).canAuthenticate(BIOMETRIC_STRONG) != BiometricManager.BIOMETRIC_SUCCESS) {
            AlertDialog.Builder(this).setMessage("Set up a fingerprint in Settings first.").setPositiveButton("OK", null).show()
            return
        }
        val server = u.getQueryParameter("s") ?: return
        val req = u.getQueryParameter("q") ?: return
        val res = u.getQueryParameter("r") ?: return
        val key = Base64.decode(u.getQueryParameter("k") ?: return, Base64.URL_SAFE or Base64.NO_PADDING)
        if (key.size != 32 || !server.startsWith("https://")) return
        val alias = "approve-sign-${System.currentTimeMillis()}"
        val pub = Gate.createSigningKey(alias)
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Pair with $mac")
            .setDescription("Your fingerprint will approve commands from this Mac.")
            .setNegativeButtonText("Cancel").setAllowedAuthenticators(BIOMETRIC_STRONG).build()
        BiometricPrompt(this, ContextCompat.getMainExecutor(this), object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                val s = result.cryptoObject?.signature ?: return
                s.update("approvegate-pair:$res".toByteArray())
                val sig = s.sign()
                val pr = Gate.Pairing(server, req, res, key, mac)
                val since = System.currentTimeMillis() / 1000 - 5
                thread {
                    val err = runCatching {
                        Gate.post(pr, JSONObject().put("type", "pair").put("name", "${Build.MANUFACTURER} ${Build.MODEL}")
                            .put("publicKey", Base64.encodeToString(pub, Base64.NO_WRAP))
                            .put("sig", Base64.encodeToString(sig, Base64.NO_WRAP)))
                        // Commit only once the Mac confirms it saved this key.
                        if (!Gate.waitForPaired(pr, since, 20_000)) throw IllegalStateException(
                            "the Mac did not confirm. Run `approve pair` on the Mac and scan its new code.")
                    }.exceptionOrNull()
                    runOnUiThread {
                        if (err != null) {
                            Gate.deleteKey(alias)
                            AlertDialog.Builder(this@MainActivity).setTitle("Not paired")
                                .setMessage("Pairing failed: ${err.message}\n\nThe existing pairing is unchanged.")
                                .setPositiveButton("OK", null).show()
                            return@runOnUiThread
                        }
                        stopService(Intent(this@MainActivity, RelayService::class.java))
                        Gate.savePairing(this@MainActivity, pr, alias)
                        Gate.addHistory(this@MainActivity, "Paired with $mac")
                        RelayService.start(this@MainActivity)
                        render()
                    }
                }
            }
        }).authenticate(info, BiometricPrompt.CryptoObject(Gate.signer(this, alias)))
    }

    @SuppressLint("BatteryLife")
    private fun askBattery() {
        startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
    }
}
