import pathlib
import unittest


class GuardStartupOrderTest(unittest.TestCase):
    def test_service_satisfies_foreground_deadline_before_reading_mutable_flags(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        source = (
            root
            / "android/app/src/main/kotlin/com/example/aicove_flutter/PersistentGuardService.kt"
        ).read_text()
        create = source.split("override fun onCreate()", 1)[1].split(
            "override fun onDestroy()", 1
        )[0]
        self.assertIn("startForegroundCompat()", create)
        self.assertLess(
            create.index("ensureNotificationChannel()"),
            create.index("startForegroundCompat()"),
        )
        self.assertNotIn("KeepAliveConfig.isGuardEnabled", create)


if __name__ == "__main__":
    unittest.main()
