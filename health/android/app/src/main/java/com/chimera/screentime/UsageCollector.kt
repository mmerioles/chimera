package com.chimera.screentime

import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import java.time.Instant

/**
 * Reconstructs foreground sessions, screen-on intervals and unlocks from the
 * raw UsageEvents stream.
 *
 * We deliberately do NOT use queryUsageStats(INTERVAL_DAILY): its buckets are
 * opaque, reset on their own schedule, and cannot be re-bucketed after the
 * fact. Raw events let the server own the bucketing, so a change to how usage
 * is attributed is a backfill rather than a permanent gap.
 */
class UsageCollector(private val context: Context) {

    data class AppSession(val pkg: String, val start: Long, val end: Long)
    data class Interval(val start: Long, val end: Long)

    data class Result(
        val appSessions: List<AppSession>,
        val screenSessions: List<Interval>,
        val unlocks: List<Long>,
        val packages: Set<String>,
    )

    fun collect(fromMillis: Long, toMillis: Long): Result {
        val usm = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val events = usm.queryEvents(fromMillis, toMillis)

        val appSessions = mutableListOf<AppSession>()
        val screenSessions = mutableListOf<Interval>()
        val unlocks = mutableListOf<Long>()

        // Only one activity is resumed at a time, but PAUSED can be missing if
        // the process died, so track the open one and close it on the next
        // RESUMED or on screen-off.
        var openPkg: String? = null
        var openStart = 0L
        var screenOnAt = 0L

        val e = UsageEvents.Event()
        while (events.hasNextEvent()) {
            events.getNextEvent(e)
            when (e.eventType) {
                UsageEvents.Event.ACTIVITY_RESUMED -> {
                    openPkg?.let { appSessions.add(AppSession(it, openStart, e.timeStamp)) }
                    openPkg = e.packageName
                    openStart = e.timeStamp
                }
                UsageEvents.Event.ACTIVITY_PAUSED,
                UsageEvents.Event.ACTIVITY_STOPPED -> {
                    if (openPkg == e.packageName) {
                        appSessions.add(AppSession(openPkg!!, openStart, e.timeStamp))
                        openPkg = null
                    }
                }
                UsageEvents.Event.SCREEN_INTERACTIVE -> screenOnAt = e.timeStamp
                UsageEvents.Event.SCREEN_NON_INTERACTIVE -> {
                    if (screenOnAt > 0) screenSessions.add(Interval(screenOnAt, e.timeStamp))
                    screenOnAt = 0
                    // A dead screen ends any session whose PAUSED never arrived.
                    openPkg?.let { appSessions.add(AppSession(it, openStart, e.timeStamp)) }
                    openPkg = null
                }
                UsageEvents.Event.KEYGUARD_HIDDEN -> unlocks.add(e.timeStamp)
            }
        }

        // Leave a still-open session for the next run rather than inventing an
        // end time. Its (package, start) key is stable, so when it is finally
        // uploaded with a real end the server upserts over the same row.
        openPkg?.let { appSessions.add(AppSession(it, openStart, toMillis)) }
        if (screenOnAt > 0) screenSessions.add(Interval(screenOnAt, toMillis))

        val cleaned = appSessions.filter { it.end > it.start }
        return Result(
            appSessions = cleaned,
            screenSessions = screenSessions.filter { it.end > it.start },
            unlocks = unlocks,
            packages = cleaned.map { it.pkg }.toSet(),
        )
    }

    companion object {
        fun iso(millis: Long): String = Instant.ofEpochMilli(millis).toString()
    }
}
