package dev.redroid.integrityprobe

import android.os.Bundle
import android.util.Log
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.IntegrityTokenRequest
import com.google.android.play.core.integrity.StandardIntegrityManager.PrepareIntegrityTokenRequest
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenRequest
import java.security.SecureRandom
import android.util.Base64

/**
 * Phase D.1 client. Mints a FRESH Play Integrity token (Classic + Standard) and prints it
 * to logcat (tag PROBE) and on screen. Feed the token to ../decode-harness/decode_token.py
 * IMMEDIATELY (single use) to decode once with our own service account.
 *
 * Set CLOUD_PROJECT_NUMBER to your GCP project number before building.
 */
class MainActivity : AppCompatActivity() {

    private val TAG = "PROBE"
    private val CLOUD_PROJECT_NUMBER = 0L // <-- set to your GCP project number

    private lateinit var out: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        out = TextView(this).apply { textSize = 11f; setPadding(24, 24, 24, 24) }
        setContentView(ScrollView(this).apply { addView(out) })
        runClassic()
        if (CLOUD_PROJECT_NUMBER != 0L) runStandard()
    }

    private fun log(s: String) { Log.i(TAG, s); runOnUiThread { out.append(s + "\n\n") } }

    private fun nonce(): String {
        val b = ByteArray(24); SecureRandom().nextBytes(b)
        return Base64.encodeToString(b, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    }

    private fun runClassic() {
        val n = nonce()
        log("CLASSIC nonce=$n")
        val mgr = IntegrityManagerFactory.create(applicationContext)
        mgr.requestIntegrityToken(IntegrityTokenRequest.builder().setNonce(n).build())
            .addOnSuccessListener { log("CLASSIC TOKEN:\n" + it.token()) }
            .addOnFailureListener { log("CLASSIC ERROR: $it") }
    }

    private fun runStandard() {
        val hashBytes = ByteArray(16); SecureRandom().nextBytes(hashBytes)
        val reqHash = Base64.encodeToString(hashBytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        val sm = IntegrityManagerFactory.createStandard(applicationContext)
        sm.prepareIntegrityToken(
            PrepareIntegrityTokenRequest.builder().setCloudProjectNumber(CLOUD_PROJECT_NUMBER).build()
        ).addOnSuccessListener { provider ->
            provider.request(StandardIntegrityTokenRequest.builder().setRequestHash(reqHash).build())
                .addOnSuccessListener { log("STANDARD TOKEN (reqHash=$reqHash):\n" + it.token()) }
                .addOnFailureListener { log("STANDARD request ERROR: $it") }
        }.addOnFailureListener { log("STANDARD prepare ERROR: $it") }
    }
}
