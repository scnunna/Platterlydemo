package com.nunna.platterly

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class DestinationsTest {
    // Unit tests run with the module directory (android/app) as the working directory.
    private val web = listOf(File("../../web"), File("../web"), File("web")).first { it.isDirectory }

    @Test fun everyDestinationHasABundledPage() {
        Destinations.all.forEach { d ->
            val file = File(web, d.path.substringBefore('?').substringBefore('#'))
            assertTrue("missing bundled page for ${d.id}: $file", file.isFile)
        }
    }

    @Test fun tvPagesCarryTheirStore() {
        assertTrue(Destinations.onlineUrl(Destinations.byId("tv-gerrard")!!).endsWith("panago/tv/index.html?s=g#tv"))
        assertTrue(Destinations.offlineUrl(Destinations.byId("tv-bremner")!!).contains("?s=b#tv"))
    }

    @Test fun onlyOwnPagesStayInTheApp() {
        assertTrue(Destinations.staysInApp(Destinations.ONLINE_BASE + "panago/index.html"))
        assertTrue(Destinations.staysInApp("https://appassets.androidplatform.net/assets/web/index.html"))
        assertFalse(Destinations.staysInApp("https://www.panago.com/"))
        assertFalse(Destinations.staysInApp("tel:3100001"))
        assertFalse(Destinations.staysInApp("https://godsmustb.github.io/other-repo/"))
    }

    @Test fun idsAreUnique() {
        assertEquals(Destinations.all.size, Destinations.all.map { it.id }.toSet().size)
        assertNotNull(Destinations.byId("spin"))
    }
}
