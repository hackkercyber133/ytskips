package com.example.ytskips

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Context
import android.graphics.Path
import android.graphics.Rect
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

class SkipService : AccessibilityService() {

    companion object {
        const val YT = "com.google.android.youtube"
        const val PREFS = "ytskips"
        const val UNSKIPPABLE_AFTER_MS = 6000L

        @Volatile
        var listener: ((Map<String, Any>) -> Unit)? = null
    }

    // ID & teks tombol bisa berubah antar versi YouTube. Sesuaikan di sini bila perlu.
    private val skipIds = setOf("$YT:id/skip_ad_button", "$YT:id/skip_button")
    private val adIds = setOf("$YT:id/ad_progress_text", "$YT:id/ad_countdown", "$YT:id/ad_badge")
    private val strongSkipTexts = setOf("skip ads", "skip ad", "lewati iklan")
    private val weakSkipTexts = setOf("skip", "lewati")
    private val adTextRegexes = listOf(
        Regex("^(ad|iklan)\\s*[·•].*", RegexOption.IGNORE_CASE),
        Regex("^(ad|iklan)\\s+\\d+\\s+(of|dari)\\s+\\d+.*", RegexOption.IGNORE_CASE),
        Regex("^(ad|iklan)$", RegexOption.IGNORE_CASE)
    )
    private val adPhrases = listOf("visit advertiser", "kunjungi pengiklan")

    private val handler = Handler(Looper.getMainLooper())
    private val prefs by lazy { getSharedPreferences(PREFS, Context.MODE_PRIVATE) }

    private var adSince = 0L
    private var noAdScans = 0
    private var countedUnskippable = false
    private var weMuted = false
    private var lastScan = 0L
    private var lastClick = 0L
    private var ignoreUntil = 0L
    private var lastStatus = ""

    private val watchdog = object : Runnable {
        override fun run() {
            if (adSince == 0L) return
            process(SystemClock.elapsedRealtime())
            if (adSince != 0L) handler.postDelayed(this, 1000)
        }
    }

    private class Scan {
        var skip: AccessibilityNodeInfo? = null
        var weakSkip: AccessibilityNodeInfo? = null
        var ad = false
        var count = 0
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (!prefs.getBoolean("enabled", true)) {
            if (adSince != 0L || weMuted) endAd("idle")
            return
        }
        val now = SystemClock.elapsedRealtime()
        if (now - lastScan < 200) return
        lastScan = now
        process(now)
    }

    private fun process(now: Long) {
        if (now < ignoreUntil) return
        val root = rootInActiveWindow
        if (root == null || root.packageName?.toString() != YT) {
            if (adSince != 0L && ++noAdScans >= 2) endAd("idle")
            return
        }
        val s = Scan()
        walk(root, s, 0)
        val adContext = s.ad || adSince != 0L
        val target = s.skip ?: if (adContext) s.weakSkip else null

        if (target != null && now - lastClick > 1000) {
            lastClick = now
            if (clickNode(target)) {
                bump("skipped")
                endAd("skipped")
                ignoreUntil = now + 1500
                return
            }
        }

        if (s.ad || target != null) {
            noAdScans = 0
            if (adSince == 0L) {
                adSince = now
                emit("ad_detected")
                handler.removeCallbacks(watchdog)
                handler.postDelayed(watchdog, 1000)
            }
            if (target == null && now - adSince >= UNSKIPPABLE_AFTER_MS) {
                if (!countedUnskippable) {
                    countedUnskippable = true
                    bump("unskippable")
                }
                if (prefs.getBoolean("mute", true)) setMute(true)
                emit("ad_unskippable")
            }
        } else if (adSince != 0L) {
            if (++noAdScans >= 2) endAd("idle")
        }
    }

    private fun walk(n: AccessibilityNodeInfo?, s: Scan, depth: Int) {
        if (n == null || depth > 40 || s.count > 2500) return
        s.count++
        if (n.isVisibleToUser) {
            val id = n.viewIdResourceName
            if (id != null) {
                if (id in skipIds && s.skip == null) s.skip = n
                if (id in adIds) s.ad = true
            }
            val texts = arrayOf(n.text?.toString()?.trim(), n.contentDescription?.toString()?.trim())
            for (t in texts) {
                if (t.isNullOrEmpty() || t.length > 40) continue
                val low = t.lowercase()
                if (low in strongSkipTexts && s.skip == null) s.skip = n
                else if (low in weakSkipTexts && s.weakSkip == null) s.weakSkip = n
                if (adTextRegexes.any { it.matches(t) } || adPhrases.any { low.contains(it) }) s.ad = true
            }
        }
        for (i in 0 until n.childCount) walk(n.getChild(i), s, depth + 1)
    }

    private fun clickNode(node: AccessibilityNodeInfo): Boolean {
        var n: AccessibilityNodeInfo? = node
        var hops = 0
        while (n != null && hops < 6) {
            if (n.isClickable && n.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true
            n = n.parent
            hops++
        }
        if (Build.VERSION.SDK_INT >= 24) {
            val r = Rect()
            node.getBoundsInScreen(r)
            if (r.width() > 0 && r.height() > 0) {
                val p = Path().apply { moveTo(r.exactCenterX(), r.exactCenterY()) }
                val g = GestureDescription.Builder()
                    .addStroke(GestureDescription.StrokeDescription(p, 0, 60))
                    .build()
                return dispatchGesture(g, null, null)
            }
        }
        return false
    }

    private fun setMute(on: Boolean) {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (on) {
            if (weMuted) return
            if (Build.VERSION.SDK_INT >= 23 && am.isStreamMute(AudioManager.STREAM_MUSIC)) return
            am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_MUTE, 0)
            weMuted = true
        } else if (weMuted) {
            am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_UNMUTE, 0)
            weMuted = false
        }
    }

    private fun bump(key: String) {
        prefs.edit().putInt(key, prefs.getInt(key, 0) + 1).apply()
    }

    private fun endAd(status: String) {
        setMute(false)
        handler.removeCallbacks(watchdog)
        adSince = 0L
        noAdScans = 0
        countedUnskippable = false
        emit(status)
    }

    private fun emit(status: String) {
        if (status == lastStatus && status != "skipped") return
        lastStatus = status
        listener?.invoke(
            mapOf(
                "status" to status,
                "skipped" to prefs.getInt("skipped", 0),
                "unskippable" to prefs.getInt("unskippable", 0)
            )
        )
    }

    override fun onInterrupt() {
        endAd("idle")
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        endAd("idle")
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        setMute(false)
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }
}
