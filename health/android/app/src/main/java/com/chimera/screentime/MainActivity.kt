package com.chimera.screentime

import android.app.Activity
import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.*
import androidx.work.*
import java.util.concurrent.TimeUnit

/**
 * One screen, one job: show whether screen time is reaching the server, and
 * make the two things that can go wrong obvious and one tap from fixed.
 *
 * There is no endpoint field. This app talks to exactly one server, so the
 * address is a constant - it was only ever a way to get the setup wrong.
 */
class MainActivity : Activity() {

    private lateinit var tokenField: EditText
    private lateinit var statusDot: View
    private lateinit var statusText: TextView
    private lateinit var statusDetail: TextView
    private lateinit var accessRow: TextView
    private lateinit var accessButton: Button

    private val ui = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            refresh()
            ui.postDelayed(this, 700)
        }
    }

    private val dark: Boolean
        get() = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES

    private val bg get() = if (dark) Color.parseColor("#0B0D10") else Color.parseColor("#F4F5F7")
    private val card get() = if (dark) Color.parseColor("#161A20") else Color.WHITE
    private val fg get() = if (dark) Color.parseColor("#F3F4F6") else Color.parseColor("#111827")
    private val muted get() = if (dark) Color.parseColor("#9CA3AF") else Color.parseColor("#6B7280")
    private val accent get() = Color.parseColor("#2563EB")
    private val okColor get() = Color.parseColor("#10B981")
    private val warnColor get() = Color.parseColor("#F59E0B")
    private val errColor get() = Color.parseColor("#EF4444")

    private fun dp(v: Int) = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics
    ).toInt()

    private fun rounded(color: Int, radius: Int = 16) = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = dp(radius).toFloat()
        setColor(color)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val prefs = getSharedPreferences(UploadWorker.PREFS, Context.MODE_PRIVATE)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(28), dp(20), dp(28))
            setBackgroundColor(bg)
        }

        root.addView(TextView(this).apply {
            text = "Screen Time"
            setTextColor(fg)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 28f)
            setTypeface(null, Typeface.BOLD)
        })
        root.addView(TextView(this).apply {
            text = "uploads to mon01"
            setTextColor(muted)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setPadding(0, dp(2), 0, dp(20))
        })

        // ---- status card ------------------------------------------------
        statusDot = View(this)
        statusText = TextView(this).apply {
            setTextColor(fg)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            setTypeface(null, Typeface.BOLD)
        }
        statusDetail = TextView(this).apply {
            setTextColor(muted)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setPadding(0, dp(6), 0, 0)
        }

        val dotRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(statusDot, LinearLayout.LayoutParams(dp(12), dp(12)).apply {
                rightMargin = dp(10)
            })
            addView(statusText)
        }

        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(card)
            setPadding(dp(18), dp(18), dp(18), dp(18))
            addView(dotRow)
            addView(statusDetail)
        }, wide().apply { bottomMargin = dp(14) })

        // ---- usage access card -------------------------------------------
        accessRow = TextView(this).apply {
            setTextColor(fg)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setTypeface(null, Typeface.BOLD)
        }
        accessButton = Button(this).apply {
            text = "Turn on usage access"
            isAllCaps = false
            setTextColor(Color.WHITE)
            background = rounded(accent, 12)
            setOnClickListener { startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)) }
        }

        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(card)
            setPadding(dp(18), dp(18), dp(18), dp(18))
            addView(accessRow)
            addView(TextView(this@MainActivity).apply {
                text = "Android only grants this from Settings. Without it the " +
                    "upload succeeds but carries nothing."
                setTextColor(muted)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                setPadding(0, dp(6), 0, dp(12))
            })
            addView(accessButton, wide())
        }, wide().apply { bottomMargin = dp(14) })

        // ---- token card ---------------------------------------------------
        tokenField = EditText(this).apply {
            hint = "paste ingest token"
            setSingleLine(true)
            setTextColor(fg)
            setHintTextColor(muted)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setText(prefs.getString(UploadWorker.KEY_TOKEN, ""))
        }

        val saveButton = Button(this).apply {
            text = "Save"
            isAllCaps = false
            setTextColor(Color.WHITE)
            background = rounded(accent, 12)
            setOnClickListener {
                prefs.edit()
                    .putString(UploadWorker.KEY_ENDPOINT, UploadWorker.ENDPOINT)
                    .putString(UploadWorker.KEY_TOKEN, tokenField.text.toString().trim())
                    .apply()
                schedule()
                syncNow()
                Toast.makeText(this@MainActivity, "Saved, syncing", Toast.LENGTH_SHORT).show()
            }
        }

        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(card)
            setPadding(dp(18), dp(18), dp(18), dp(18))
            addView(TextView(this@MainActivity).apply {
                text = "Ingest token"
                setTextColor(fg)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
                setTypeface(null, Typeface.BOLD)
                setPadding(0, 0, 0, dp(8))
            })
            addView(tokenField, wide())
            addView(saveButton, wide().apply { topMargin = dp(12) })
        }, wide().apply { bottomMargin = dp(14) })

        root.addView(Button(this).apply {
            text = "Sync now"
            isAllCaps = false
            setTextColor(fg)
            background = rounded(card, 12)
            setOnClickListener { syncNow() }
        }, wide())

        setContentView(ScrollView(this).apply {
            setBackgroundColor(bg)
            addView(root)
        })

        // Uploads run on their own every 15 minutes - WorkManager will not
        // schedule periodic work more often than that - plus once whenever
        // this screen is opened, so "is it working" is never a wait.
        schedule()
        refresh()
    }

    private fun wide() = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT
    )

    override fun onResume() {
        super.onResume()
        ui.post(tick)
        if (hasUsageAccess() && !getSharedPreferences(UploadWorker.PREFS, Context.MODE_PRIVATE)
                .getString(UploadWorker.KEY_TOKEN, "").isNullOrBlank()
        ) syncNow()
    }

    override fun onPause() {
        super.onPause()
        ui.removeCallbacks(tick)
    }

    private fun syncNow() {
        WorkManager.getInstance(this).enqueue(
            OneTimeWorkRequestBuilder<UploadWorker>()
                .setConstraints(
                    Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
                )
                .build()
        )
    }

    private fun refresh() {
        val prefs = getSharedPreferences(UploadWorker.PREFS, Context.MODE_PRIVATE)
        val access = hasUsageAccess()

        accessRow.text = if (access) "Usage access: on" else "Usage access: OFF"
        accessRow.setTextColor(if (access) okColor else errColor)
        accessButton.visibility = if (access) View.GONE else View.VISIBLE

        val state = prefs.getString(UploadWorker.KEY_SYNC_STATE, "idle")
        val last = prefs.getLong(UploadWorker.KEY_LAST_SYNC_AT, 0L)
        val detail = prefs.getString(UploadWorker.KEY_LAST_RESULT, "")

        val (colour, headline) = when {
            !access -> errColor to "Not collecting"
            state == "running" -> warnColor to "Syncing…"
            state == "ok" -> okColor to "Synced"
            state == "error" -> errColor to "Sync failed"
            else -> muted to "Waiting to sync"
        }

        statusDot.background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(colour)
        }
        statusText.text = headline
        statusText.setTextColor(fg)

        statusDetail.text = buildString {
            append("Last sync: ")
            append(if (last == 0L) "never" else ago(last))
            if (!detail.isNullOrBlank()) {
                append('\n')
                append(detail)
            }
        }
    }

    private fun ago(t: Long): String {
        val s = (System.currentTimeMillis() - t) / 1000
        return when {
            s < 60 -> "just now"
            s < 3600 -> "${s / 60} min ago"
            s < 86400 -> "${s / 3600} h ago"
            else -> "${s / 86400} d ago"
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
     * Every 15 minutes: WorkManager's floor for periodic work. UsageStatsManager
     * keeps about a week of raw events, so frequent small uploads mean a few
     * days of connectivity trouble never costs data.
     */
    private fun schedule() {
        val request = PeriodicWorkRequestBuilder<UploadWorker>(15, TimeUnit.MINUTES)
            .setConstraints(
                Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
            )
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 5, TimeUnit.MINUTES)
            .build()

        WorkManager.getInstance(this).enqueueUniquePeriodicWork(
            UploadWorker.WORK_NAME,
            ExistingPeriodicWorkPolicy.UPDATE,
            request
        )
    }
}
