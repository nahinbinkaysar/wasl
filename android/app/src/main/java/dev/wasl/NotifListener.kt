package dev.wasl

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject

/** Mirrors the phone's notifications to the Mac. The system binds it once notification access is granted. */
class NotifListener : NotificationListenerService() {
    override fun onListenerConnected() {
        instance = this
        SyncService.instance?.send(snapshot())
    }

    override fun onListenerDisconnected() {
        instance = null
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        toJson(sbn)?.let { SyncService.instance?.send(it.put("t", "notif")) }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        SyncService.instance?.send(JSONObject().put("t", "notif_removed").put("id", sbn.key))
    }

    /** Everything currently showing; the Mac uses it to catch up after (re)connecting. */
    fun snapshot(): JSONObject = JSONObject().put("t", "notifs")
        .put("items", JSONArray(runCatching { activeNotifications }.getOrNull().orEmpty().mapNotNull(::toJson)))

    private fun toJson(sbn: StatusBarNotification): JSONObject? {
        val n = sbn.notification
        // Skip ongoing (music, downloads), our own, and group summaries (their children carry the content).
        if (!sbn.isClearable || sbn.packageName == packageName || n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return null
        val e = n.extras
        val title = e.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = (e.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: e.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty()
        if (title.isEmpty() && text.isEmpty()) return null
        val app = runCatching {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(sbn.packageName, 0)).toString()
        }.getOrDefault(sbn.packageName)
        return JSONObject().put("id", sbn.key).put("app", app).put("title", title).put("text", text).put("time", sbn.postTime)
    }

    companion object {
        var instance: NotifListener? = null
    }
}
