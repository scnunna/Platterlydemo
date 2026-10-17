package com.nunna.platterly

/** Where each start-screen button goes. Online first (the live site: GitHub Pages, or the store laptop's tunnel when built with PL_ONLINE_BASE), bundled copy offline. */
object Destinations {
    val ONLINE_BASE = BuildConfig.ONLINE_BASE
    const val OFFLINE_BASE = "https://appassets.androidplatform.net/assets/web/"

    data class Dest(val id: String, val title: String, val subtitle: String, val path: String, val isTv: Boolean = false)

    val all = listOf(
        Dest("platterly", "Platterly catering", "Order for your team, track orders, rewards. Client and admin views.", "index.html"),
        Dest("spin", "Panago Spin & Win", "The customer game the QR code opens. Spin, join, get a coupon.", "panago/index.html"),
        Dest("wetzels-spin", "Wetzel's Spin & Win", "Wetzel's Pretzels, CF Toronto Eaton Centre. Spin, join, get a WP- coupon.", "wetzels/index.html"),
        Dest("order", "Platterly order", "Order with a Platterly code: pickup or delivery, same price as the store.", "order/index.html"),
        Dest("admin", "Leads portal (staff)", "Orders, leads, redemptions, catering. Super admin also gets the client onboarding board.", "admin/index.html"),
        Dest("tv-gerrard", "TV screens · Gerrard", "Six-page window loop for 44 Gerrard St W. Full screen.", "panago/tv/index.html?s=g#tv", isTv = true),
        Dest("tv-bremner", "TV screens · Bremner", "Six-page window loop for 133 Bremner Blvd. Full screen.", "panago/tv/index.html?s=b#tv", isTv = true),
    )

    fun byId(id: String?): Dest? = all.firstOrNull { it.id == id }
    fun onlineUrl(d: Dest): String = ONLINE_BASE + d.path
    fun offlineUrl(d: Dest): String = OFFLINE_BASE + d.path

    /** Links the app keeps inside its own WebView; everything else (tel:, panago.com, ...) opens outside. */
    fun staysInApp(url: String): Boolean = url.startsWith(ONLINE_BASE) || url.startsWith(OFFLINE_BASE)
}
