package dev.wasl

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.text.InputType
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast

class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val prefs = getSharedPreferences("wasl", MODE_PRIVATE)

        fun field(hint: String, pref: String, secret: Boolean = false) = EditText(this).apply {
            this.hint = hint
            setText(prefs.getString(pref, ""))
            if (secret) inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        }
        val key = field("Pairing key (Mac menu → Copy pairing key)", "key", secret = true)
        // `adb shell am start -n dev.wasl/.MainActivity --es key <KEY>` pre-fills it.
        intent.getStringExtra("key")?.let(key::setText)
        val relay = field("Relay URL (optional), e.g. wss://relay.example.com", "relayUrl")
        val token = field("Invite token", "relayToken", secret = true)

        val save = Button(this).apply {
            text = "Save & start"
            setOnClickListener {
                if (Prefs.decodeKey(key.text.toString()) == null) {
                    Toast.makeText(context, "Pairing key must be 32 bytes, base64", Toast.LENGTH_LONG).show()
                    return@setOnClickListener
                }
                prefs.edit()
                    .putString("key", key.text.toString().trim())
                    .putString("relayUrl", relay.text.toString().trim())
                    .putString("relayToken", token.text.toString().trim())
                    .apply()
                startForegroundService(Intent(context, SyncService::class.java))
            }
        }
        val help = TextView(this).apply {
            setTextIsSelectable(true)
            text = """
                For background clipboard sync, run once from your computer:
                adb shell pm grant $packageName android.permission.READ_LOGS
                adb shell appops set $packageName SYSTEM_ALERT_WINDOW allow
            """.trimIndent()
        }

        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 96, 48, 48)
            listOf(key, relay, token, save, help).forEach(::addView)
        })
    }
}
