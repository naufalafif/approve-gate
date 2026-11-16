package id.naufal.approvegate

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.CopyOnWriteArraySet
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Pairing state, crypto and relay calls shared by the screens and the service. */
object Gate {
    private const val LEGACY_SIGN_ALIAS = "approve-sign"
    private const val WRAP_ALIAS = "approve-wrap"

    data class Pairing(val server: String, val req: String, val res: String, val key: ByteArray, val mac: String)

    /** Request ids answered elsewhere (on the Mac, or expired); open approval screens listen. */
    val cancelListeners = CopyOnWriteArraySet<(String) -> Unit>()

    private fun prefs(ctx: Context) = ctx.getSharedPreferences("gate", Context.MODE_PRIVATE)
    private fun ks() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    fun pairing(ctx: Context): Pairing? {
        val p = prefs(ctx)
        val keyWrapped = p.getString("key", null) ?: return null
        val key = runCatching { unwrap(keyWrapped) }.getOrNull() ?: return null
        return Pairing(p.getString("server", "")!!, p.getString("req", "")!!, p.getString("res", "")!!,
            key, p.getString("mac", "Mac")!!)
    }

    /** Commit a pairing the Mac has confirmed: switch to its key and delete the previous one. */
    fun savePairing(ctx: Context, pr: Pairing, alias: String) {
        val old = signAlias(ctx)
        prefs(ctx).edit().putString("server", pr.server).putString("req", pr.req).putString("res", pr.res)
            .putString("key", wrap(pr.key)).putString("mac", pr.mac).putString("alias", alias).remove("lastId").apply()
        if (old != alias) runCatching { ks().deleteEntry(old) }
    }

    fun unpair(ctx: Context) {
        val alias = signAlias(ctx)
        prefs(ctx).edit().clear().apply()
        runCatching { ks().deleteEntry(alias) }
    }

    /** Key alias of the current pairing (each pairing gets its own key). */
    private fun signAlias(ctx: Context) = prefs(ctx).getString("alias", null) ?: LEGACY_SIGN_ALIAS

    fun deleteKey(alias: String) { runCatching { ks().deleteEntry(alias) } }

    fun lastId(ctx: Context): String? = prefs(ctx).getString("lastId", null)
    fun setLastId(ctx: Context, id: String) = prefs(ctx).edit().putString("lastId", id).apply()

    // ---- the fingerprint-bound signing key ----

    /** New P-256 key in secure hardware under a fresh alias; the current pairing's key is untouched
     *  until savePairing. Every use needs a fresh strong-biometric match. */
    fun createSigningKey(alias: String): ByteArray {
        fun spec(strongBox: Boolean) = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setUserAuthenticationRequired(true)
            .setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
            .setInvalidatedByBiometricEnrollment(true)
            .setIsStrongBoxBacked(strongBox)
            .build()
        val gen = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        val kp = try {
            gen.initialize(spec(true)); gen.generateKeyPair()
        } catch (e: StrongBoxUnavailableException) {
            gen.initialize(spec(false)); gen.generateKeyPair()
        }
        return kp.public.encoded // X.509 SubjectPublicKeyInfo, DER
    }

    /** Signature object to hand to BiometricPrompt. Throws KeyPermanentlyInvalidatedException
     *  when fingerprints changed since pairing. */
    fun signer(ctx: Context, alias: String = signAlias(ctx)): Signature {
        val key = ks().getKey(alias, null) as PrivateKey
        return Signature.getInstance("SHA256withECDSA").apply { initSign(key) }
    }

    // ---- message encryption (AES-256-GCM, nonce || ciphertext || tag, base64) ----

    fun seal(key: ByteArray, plain: ByteArray): String {
        val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        return Base64.encodeToString(iv + c.doFinal(plain), Base64.NO_WRAP)
    }

    fun open(key: ByteArray, b64: String): ByteArray? = runCatching {
        val d = Base64.decode(b64, Base64.DEFAULT)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, d, 0, 12))
        c.doFinal(d, 12, d.size - 12)
    }.getOrNull()

    // The pairing key at rest is wrapped by a keystore key that never leaves the hardware.
    private fun wrapKey(): SecretKey {
        (ks().getKey(WRAP_ALIAS, null) as? SecretKey)?.let { return it }
        val g = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        g.init(KeyGenParameterSpec.Builder(WRAP_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256).build())
        return g.generateKey()
    }

    private fun wrap(data: ByteArray): String {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, wrapKey())
        return Base64.encodeToString(c.iv + c.doFinal(data), Base64.NO_WRAP)
    }

    private fun unwrap(s: String): ByteArray {
        val d = Base64.decode(s, Base64.DEFAULT)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, wrapKey(), GCMParameterSpec(128, d, 0, 12))
        return c.doFinal(d, 12, d.size - 12)
    }

    // ---- relay ----

    /** Blocking: call off the main thread. */
    fun post(p: Pairing, obj: JSONObject) {
        val conn = URL("${p.server}/${p.res}").openConnection() as HttpURLConnection
        conn.requestMethod = "POST"
        conn.doOutput = true
        conn.connectTimeout = 10_000
        conn.readTimeout = 10_000
        conn.outputStream.use { it.write(seal(p.key, obj.toString().toByteArray()).toByteArray()) }
        val code = conn.responseCode
        conn.disconnect()
        if (code >= 300) throw IllegalStateException("relay returned HTTP $code")
    }

    /** Blocking: polls the request topic for the Mac's "paired" reply. */
    fun waitForPaired(p: Pairing, since: Long, timeoutMs: Long): Boolean {
        val end = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < end) {
            runCatching {
                val c = URL("${p.server}/${p.req}/json?poll=1&since=$since").openConnection() as HttpURLConnection
                c.connectTimeout = 10_000; c.readTimeout = 10_000
                c.inputStream.bufferedReader().useLines { lines ->
                    for (line in lines) {
                        val ev = runCatching { JSONObject(line) }.getOrNull() ?: continue
                        val plain = open(p.key, ev.optString("message")) ?: continue
                        if (runCatching { JSONObject(String(plain)).optString("type") }.getOrNull() == "paired") return true
                    }
                }
            }
            Thread.sleep(2000)
        }
        return false
    }

    // ---- history shown on the main screen ----

    fun addHistory(ctx: Context, line: String) {
        val p = prefs(ctx)
        val arr = JSONArray(p.getString("history", "[]"))
        val stamp = SimpleDateFormat("d MMM HH:mm", Locale.getDefault()).format(Date())
        val out = JSONArray().put("$stamp  $line")
        for (i in 0 until minOf(arr.length(), 29)) out.put(arr.getString(i))
        p.edit().putString("history", out.toString()).apply()
    }

    fun history(ctx: Context): List<String> {
        val arr = JSONArray(prefs(ctx).getString("history", "[]"))
        return (0 until arr.length()).map { arr.getString(it) }
    }
}
