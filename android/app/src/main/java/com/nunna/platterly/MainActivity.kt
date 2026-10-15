package com.nunna.platterly

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.TypedValue
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/** Start screen: pick what this device shows. A TV box can be set to open its TV loop straight away. */
class MainActivity : Activity() {
    private val prefs by lazy { getSharedPreferences("platterly", MODE_PRIVATE) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(buildUi())
        val auto = Destinations.byId(prefs.getString("autoOpen", null))
        if (auto != null && savedInstanceState == null && !intent.getBooleanExtra(EXTRA_FROM_WEB, false)) open(auto)
    }

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    private fun buildUi(): ScrollView {
        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(20), dp(28), dp(20), dp(28)) }
        col.addView(TextView(this).apply { text = "platterly"; textSize = 30f; setTypeface(typeface, Typeface.BOLD); setTextColor(TEAL) })
        col.addView(TextView(this).apply { text = "Catering at menu price. Choose what this device shows."; textSize = 15f; setTextColor(MUTED); setPadding(0, dp(4), 0, dp(18)) })
        val keep = CheckBox(this).apply {
            text = "Open the TV screens automatically on this device (for the store TV box)"
            setTextColor(INK); isChecked = prefs.getString("autoOpen", null)?.startsWith("tv") == true
        }
        Destinations.all.forEach { d ->
            val hero = d.id == "spin"
            val card = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL; setPadding(dp(16), dp(14), dp(16), dp(14)); isFocusable = true; isClickable = true
                background = GradientDrawable().apply { cornerRadius = dp(14).toFloat(); setColor(if (hero) PURPLE else Color.WHITE); setStroke(dp(2), if (hero) PURPLE else LINE) }
                contentDescription = d.title
                setOnClickListener {
                    prefs.edit().putString("autoOpen", if (d.isTv && keep.isChecked) d.id else null).apply()
                    open(d)
                }
            }
            card.addView(TextView(this).apply { text = d.title; textSize = 18f; setTypeface(typeface, Typeface.BOLD); setTextColor(if (hero) YELLOW else INK) })
            card.addView(TextView(this).apply { text = d.subtitle; textSize = 13.5f; setTextColor(if (hero) Color.WHITE else MUTED) })
            col.addView(card, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(12) })
        }
        col.addView(keep)
        val version = packageManager.getPackageInfo(packageName, 0).versionName
        col.addView(TextView(this).apply { text = "Version $version · updates through Obtainium"; textSize = 12f; setTextColor(MUTED); setPadding(0, dp(16), 0, 0) })
        return ScrollView(this).apply { setBackgroundColor(BG); addView(col) }
    }

    private fun open(d: Destinations.Dest) = startActivity(Intent(this, WebActivity::class.java).putExtra(WebActivity.EXTRA_DEST, d.id))

    companion object {
        const val EXTRA_FROM_WEB = "fromWeb"
        val TEAL = Color.parseColor("#0E4D4A"); val INK = Color.parseColor("#13201F"); val MUTED = Color.parseColor("#56645F")
        val LINE = Color.parseColor("#D3DBD6"); val BG = Color.parseColor("#F3F5F2")
        val PURPLE = Color.parseColor("#522171"); val YELLOW = Color.parseColor("#FAEE23")
    }
}
