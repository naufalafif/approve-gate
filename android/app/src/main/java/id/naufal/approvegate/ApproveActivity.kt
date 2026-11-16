package id.naufal.approvegate

import android.app.NotificationManager
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.util.Base64
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import org.json.JSONObject
import kotlin.concurrent.thread

/** Shows exactly what is being approved, then asks for a fingerprint that signs that request. */
class ApproveActivity : AppCompatActivity() {
    private lateinit var plain: ByteArray
    private lateinit var req: JSONObject
    private lateinit var status: TextView
    private lateinit var countdown: TextView
    private lateinit var buttons: LinearLayout
    private lateinit var progress: android.widget.ProgressBar
    private var total = 0L
    private var finished = false
    private var prompt: BiometricPrompt? = null
    private val handler = Handler(Looper.getMainLooper())
    private val onCancel: (String) -> Unit = { id ->
        if (id == req.optString("id")) runOnUiThread { done("Answered on the Mac", Ui.MUTED) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        load(intent)
        Gate.cancelListeners.add(onCancel)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handler.removeCallbacksAndMessages(null)
        // A newer request replaces the screen: close a fingerprint prompt that was opened for the old
        // one, so one fingerprint can never sign a request the prompt did not show.
        prompt?.cancelAuthentication()
        prompt = null
        finished = false
        load(intent)
    }

    override fun onDestroy() {
        Gate.cancelListeners.remove(onCancel)
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    private fun load(i: Intent) {
        plain = Base64.decode(i.getStringExtra("plain") ?: run { finish(); return }, Base64.DEFAULT)
        req = JSONObject(String(plain))
        render()
        tick()
    }

    private fun render() {
        val c = this
        val col = Ui.column(c)
        val prod = req.optBoolean("production")

        if (prod) col.addView(Ui.badge(c, "PRODUCTION", Ui.DANGER), Ui.lp(c, width = LinearLayout.LayoutParams.WRAP_CONTENT))
        col.addView(Ui.text(c, "Approve ${req.optString("cli")}?", 28f, bold = true), Ui.lp(c, top = if (prod) 12 else 0))
        req.optString("target").takeIf { it.isNotBlank() }?.let {
            col.addView(Ui.text(c, it, 15f, if (prod) Ui.DANGER else Ui.MUTED, bold = prod), Ui.lp(c, top = 4))
        }

        col.addView(Ui.label(c, "Command"))
        val cmd = Ui.card(c, if (prod) Ui.DANGER_SURFACE else Ui.SURFACE)
        cmd.addView(Ui.text(c, req.optString("command"), 15f, mono = true).apply { setTextIsSelectable(true) })
        col.addView(cmd)

        val details = Ui.card(c, android.graphics.Color.WHITE, Ui.LINE)
        var first = true
        fun row(name: String, value: String) {
            if (value.isBlank()) return
            if (!first) details.addView(Ui.divider(c).apply { (layoutParams as LinearLayout.LayoutParams).topMargin = Ui.dp(c, 12) })
            details.addView(Ui.text(c, name, 13f, Ui.MUTED), Ui.lp(c, top = if (first) 0 else 12))
            details.addView(Ui.text(c, value, 15f), Ui.lp(c, top = 2))
            first = false
        }
        row("Requested by", req.optString("caller"))
        if (req.has("reason")) row("Reason given (not verified)", req.optString("reason"))
        val where = listOf(req.optString("cwd"), req.optString("host")).filter { it.isNotBlank() }.joinToString(" on ")
        row("From", where)
        col.addView(details, Ui.lp(c, top = 16))

        // Pinned to the bottom, within thumb reach: time left, then the two choices.
        val bar = Ui.column(c, top = 12, bottom = 12)
        val timeRow = Ui.row(c)
        progress = android.widget.ProgressBar(c, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 1000
            progressTintList = android.content.res.ColorStateList.valueOf(Ui.PURPLE)
            progressBackgroundTintList = android.content.res.ColorStateList.valueOf(Ui.LINE)
        }
        timeRow.addView(progress, Ui.lp(c, weight = 1f))
        countdown = Ui.text(c, "", 13f, Ui.MUTED).apply { setPadding(Ui.dp(c, 12), 0, 0, 0) }
        timeRow.addView(countdown, Ui.lp(c, width = LinearLayout.LayoutParams.WRAP_CONTENT))
        bar.addView(timeRow)
        status = Ui.text(c, "", 17f, bold = true).apply { gravity = Gravity.CENTER; visibility = android.view.View.GONE }
        bar.addView(status, Ui.lp(c, top = 12))
        buttons = LinearLayout(c).apply { orientation = LinearLayout.HORIZONTAL }
        buttons.addView(Ui.button(c, "Deny", false) { deny() }, Ui.lp(c, weight = 1f).apply { marginEnd = Ui.dp(c, 12) })
        buttons.addView(Ui.button(c, "Approve", true) { approve() }, Ui.lp(c, weight = 1.6f))
        bar.addView(buttons, Ui.lp(c, top = 12))

        Ui.screen(this, col, bar)
    }

    private fun secondsLeft() = req.optLong("expiresAt") - System.currentTimeMillis() / 1000

    private fun tick() {
        if (finished) return
        val s = secondsLeft()
        if (s <= 0) { done("Expired", Ui.MUTED); return }
        if (total <= 0) total = s
        val urgent = s <= 15
        countdown.text = "${s}s left"
        countdown.setTextColor(if (urgent) Ui.DANGER else Ui.MUTED)
        progress.progress = (1000 * s / total).toInt()
        progress.progressTintList = android.content.res.ColorStateList.valueOf(if (urgent) Ui.DANGER else Ui.PURPLE)
        handler.postDelayed({ tick() }, 1000)
    }

    private fun approve() {
        val sig = try {
            Gate.signer(this)
        } catch (e: KeyPermanentlyInvalidatedException) {
            say("Fingerprints changed since pairing. Pair again from the Mac (approve pair).", Ui.DANGER)
            return
        } catch (e: Exception) {
            say("Signing key unavailable: ${e.message}", Ui.DANGER); return
        }
        // Bind the signature to the request shown in this prompt, even if a newer one arrives.
        val shownPlain = plain
        val shownId = req.optString("id")
        val cmd = req.optString("command")
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle((if (req.optBoolean("production")) "PRODUCTION: " else "") + "Approve ${req.optString("cli")}")
            .setSubtitle(req.optString("target").ifBlank { req.optString("host") })
            .setDescription(if (cmd.length > 220) cmd.take(220) + "…" else cmd)
            .setNegativeButtonText("Cancel")
            .setAllowedAuthenticators(BIOMETRIC_STRONG)
            .setConfirmationRequired(true)
            .build()
        val bp = BiometricPrompt(this, ContextCompat.getMainExecutor(this), object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                prompt = null
                if (shownId != req.optString("id")) return // the screen moved on to another request
                val s = result.cryptoObject?.signature ?: return
                // Sign the request's SHA-256, not the request itself: StrongBox chips (Xiaomi, Pixel)
                // lose the fingerprint authorisation when a long message is streamed in chunks.
                val der = try {
                    s.update(java.security.MessageDigest.getInstance("SHA-256").digest(shownPlain))
                    s.sign()
                } catch (e: Exception) {
                    say("Signing failed: ${e.message?.take(120)}", Ui.DANGER)
                    return
                }
                send(JSONObject().put("type", "response").put("id", shownId).put("decision", "approve")
                    .put("sig", Base64.encodeToString(der, Base64.NO_WRAP)), "Approved", Ui.OK)
            }
            override fun onAuthenticationError(code: Int, msg: CharSequence) {
                prompt = null
                if (code == BiometricPrompt.ERROR_CANCELED) return
                if (code != BiometricPrompt.ERROR_NEGATIVE_BUTTON && code != BiometricPrompt.ERROR_USER_CANCELED) {
                    say(msg, Ui.DANGER)
                }
            }
        })
        prompt = bp
        bp.authenticate(info, BiometricPrompt.CryptoObject(sig))
    }

    private fun deny() {
        send(JSONObject().put("type", "response").put("id", req.optString("id")).put("decision", "deny"), "Denied", Ui.DANGER)
    }

    private fun send(msg: JSONObject, label: String, color: Int) {
        val p = Gate.pairing(this) ?: return
        for (i in 0 until buttons.childCount) buttons.getChildAt(i).apply { isEnabled = false; alpha = 0.4f }
        say("Sending…", Ui.MUTED)
        thread {
            val err = runCatching { Gate.post(p, msg) }.exceptionOrNull()
            runOnUiThread {
                if (err != null) {
                    for (i in 0 until buttons.childCount) buttons.getChildAt(i).apply { isEnabled = true; alpha = 1f }
                    say("Could not reach the relay: ${err.message}", Ui.DANGER)
                } else {
                    Gate.addHistory(this, "$label: ${req.optString("command").take(80)}")
                    done(label, color)
                }
            }
        }
    }

    private fun done(label: String, color: Int) {
        if (finished) return
        finished = true
        getSystemService(NotificationManager::class.java).cancel(RelayService.notifId(req.optString("id")))
        // The result takes the buttons' place, so nothing else on the screen moves.
        buttons.visibility = android.view.View.GONE
        countdown.text = ""
        progress.progressTintList = android.content.res.ColorStateList.valueOf(color)
        say(label, color)
        status.textSize = 17f
        status.minHeight = Ui.dp(this, 52)
        handler.postDelayed({ finish() }, 1500)
    }

    /** A short message above the buttons: progress, an error, or the result. */
    private fun say(text: CharSequence, color: Int) {
        status.visibility = android.view.View.VISIBLE
        status.textSize = 14f
        status.setTextColor(color)
        status.text = text
    }
}
