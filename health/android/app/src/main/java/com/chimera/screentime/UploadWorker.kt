package com.chimera.screentime

import android.content.Context
import android.content.pm.PackageManager
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Collects everything since the last successful upload and posts it.
 *
 * The watermark only advances on a 2xx, and the server dedupes on
 * (package, start), so a failed or retried upload costs a duplicate request
 * rather than duplicate or missing data.
 */
class UploadWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {

    override suspend fun doWork(): Result {
        val prefs = applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val endpoint = prefs.getString(KEY_ENDPOINT, null) ?: return Result.failure()
        val token = prefs.getString(KEY_TOKEN, null) ?: return Result.failure()

        val now = System.currentTimeMillis()
        // UsageStatsManager keeps roughly a week of raw events; never reach
        // further back than that or the window silently returns partial data.
        val floor = now - 6L * 24 * 60 * 60 * 1000
        val since = maxOf(prefs.getLong(KEY_WATERMARK, now - 24 * 60 * 60 * 1000), floor)
        if (now - since < 60_000) return Result.success()

        val data = UsageCollector(applicationContext).collect(since, now)
        val payload = buildPayload(data, since, now)

        // Every outcome is written to KEY_LAST_RESULT and shown on the setup
        // screen. Uploads run in a background worker with no UI of their own,
        // so a swallowed exception here is indistinguishable from "nothing
        // happened" - which is exactly how a blocked cleartext request looks.
        return try {
            val code = post(endpoint, token, payload)
            if (code in 200..299) {
                prefs.edit()
                    .putLong(KEY_WATERMARK, now)
                    .putString(KEY_LAST_RESULT, "OK ($code) at " + java.util.Date())
                    .apply()
                Result.success()
            } else if (code in 500..599) {
                prefs.edit().putString(KEY_LAST_RESULT, "server error $code, will retry").apply()
                Result.retry()
            } else {
                // 4xx is our bug, not a transient fault; retrying cannot fix it.
                prefs.edit().putString(KEY_LAST_RESULT, "rejected: HTTP $code").apply()
                Result.failure()
            }
        } catch (t: Throwable) {
            prefs.edit()
                .putString(KEY_LAST_RESULT, t.javaClass.simpleName + ": " + (t.message ?: "no detail"))
                .apply()
            Result.retry()
        }
    }

    private fun buildPayload(data: UsageCollector.Result, from: Long, to: Long): JSONObject {
        val pm = applicationContext.packageManager

        val apps = JSONArray()
        data.packages.forEach { pkg ->
            val label = try {
                pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
            } catch (e: PackageManager.NameNotFoundException) {
                pkg   // uninstalled since the session; the package name still identifies it
            }
            apps.put(JSONObject().put("package", pkg).put("label", label))
        }

        val sessions = JSONArray()
        data.appSessions.forEach {
            sessions.put(
                JSONObject()
                    .put("package", it.pkg)
                    .put("start", UsageCollector.iso(it.start))
                    .put("end", UsageCollector.iso(it.end))
            )
        }

        val screen = JSONArray()
        data.screenSessions.forEach {
            screen.put(
                JSONObject()
                    .put("start", UsageCollector.iso(it.start))
                    .put("end", UsageCollector.iso(it.end))
            )
        }

        val unlocks = JSONArray()
        data.unlocks.forEach { unlocks.put(JSONObject().put("ts", UsageCollector.iso(it))) }

        return JSONObject()
            .put("device_id", android.os.Build.MODEL.replace(" ", "-").take(64))
            .put("schema_version", 1)
            .put("window_start", UsageCollector.iso(from))
            .put("window_end", UsageCollector.iso(to))
            .put("apps", apps)
            .put("app_sessions", sessions)
            .put("screen_sessions", screen)
            .put("unlocks", unlocks)
    }

    private fun post(endpoint: String, token: String, body: JSONObject): Int {
        val conn = (URL(endpoint).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            connectTimeout = 15_000
            readTimeout = 60_000
            setRequestProperty("Content-Type", "application/json")
            setRequestProperty("Authorization", "Bearer $token")
        }
        return try {
            conn.outputStream.use { it.write(body.toString().toByteArray()) }
            conn.responseCode
        } finally {
            conn.disconnect()
        }
    }

    companion object {
        const val PREFS = "chimera_screentime"
        const val KEY_ENDPOINT = "endpoint"
        const val KEY_TOKEN = "token"
        const val KEY_WATERMARK = "watermark"
        const val KEY_LAST_RESULT = "last_result"
        const val WORK_NAME = "screentime-upload"
    }
}
