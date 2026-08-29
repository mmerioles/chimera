package com.chimera.screentime

import android.app.Activity
import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.widget.*
import androidx.work.*
import java.util.concurrent.TimeUnit

/**
 * Setup screen: endpoint, token, usage-access permission, and a manual sync
 * for checking the pipeline end to end.
 */
class MainActivity : Activity() {

    private lateinit var endpoint: EditText
    private lateinit var token: EditText
    private lateinit var status: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val prefs = getSharedPreferences(UploadWorker.PREFS, Context.MODE_PRIVATE)

        endpoint = EditText(this).apply {
            hint = "https://mon01.tailnet.ts.net:8000/v1/ingest/phone_screentime"
            setText(prefs.getString(UploadWorker.KEY_ENDPOINT, ""))
        }
        token = EditText(this).apply {
            hint = "ingest token"
            setText(prefs.getString(UploadWorker.KEY_TOKEN, ""))
        }
        status = TextView(this)

        val save = Button(this).apply {
            text = "Save & schedule"
            setOnClickListener {
                prefs.edit()
                    .putString(UploadWorker.KEY_ENDPOINT, endpoint.text.toString().trim())
                    .putString(UploadWorker.KEY_TOKEN, token.text.toString().trim())
                    .apply()
                schedule()
                refresh()
                Toast.makeText(this@MainActivity, "Scheduled", Toast.LENGTH_SHORT).show()
            }
        }

        val grant = Button(this).apply {
            text = "Grant usage access"
            setOnClickListener {
                startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
            }
        }

        val syncNow = Button(this).apply {
            text = "Sync now"
            setOnClickListener {
                WorkManager.getInstance(this@MainActivity).enqueue(
                    OneTimeWorkRequestBuilder<UploadWorker>()
                        .setConstraints(
                            Constraints.Builder()
                                .setRequiredNetworkType(NetworkType.CONNECTED)
                                .build()
                        )
                        .build()
                )
                Toast.makeText(this@MainActivity, "Sync enqueued", Toast.LENGTH_SHORT).show()
            }
        }

        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 48, 48, 48)
            addView(TextView(this@MainActivity).apply { text = "Ingest endpoint" })
            addView(endpoint)
            addView(TextView(this@MainActivity).apply { text = "Bearer token" })
            addView(token)
            addView(save); addView(grant); addView(syncNow); addView(status)
        })

        refresh()
    }

    override fun onResume() { super.onResume(); refresh() }

    private fun refresh() {
        val prefs = getSharedPreferences(UploadWorker.PREFS, Context.MODE_PRIVATE)
        val wm = prefs.getLong(UploadWorker.KEY_WATERMARK, 0L)
        status.text = buildString {
            append("Usage access: ").append(if (hasUsageAccess()) "granted" else "NOT granted").append('\n')
            append("Last upload: ")
            append(if (wm == 0L) "never" else java.util.Date(wm).toString())
        }
    }

    private fun hasUsageAccess(): Boolean {
        val ops = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = ops.unsafeCheckOpNoThrow(
            AppOpsManager.OPSTR_GET_USAGE_STATS, android.os.Process.myUid(), packageName
        )
        return mode == AppOpsManager.MODE_ALLOWED
    }

    /**
     * Every 2 hours rather than nightly: UsageStatsManager only retains raw
     * events for about a week, and frequent small uploads mean a few days of
     * connectivity trouble never costs data.
     */
    private fun schedule() {
        val request = PeriodicWorkRequestBuilder<UploadWorker>(2, TimeUnit.HOURS)
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .build()
            )
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.MINUTES)
            .build()

        WorkManager.getInstance(this).enqueueUniquePeriodicWork(
            UploadWorker.WORK_NAME,
            ExistingPeriodicWorkPolicy.UPDATE,
            request
        )
    }
}
