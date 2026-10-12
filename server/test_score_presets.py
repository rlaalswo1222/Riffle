import unittest

from server import score_presets


class ScorePresetTest(unittest.TestCase):
    def test_attached_scores_cover_every_system_through_measure_108(self):
        presets = score_presets._PRESETS
        self.assertEqual({p["part"] for p in presets.values()}, {"keyboard", "guitar"})

        expected_measures = list(range(1, 109, 4))
        for preset in presets.values():
            anchors = preset["anchors"]
            self.assertEqual([a["measure"] for a in anchors], expected_measures)
            self.assertEqual(anchors[-1]["end_measure"], 109)
            self.assertTrue(all(a["x_start"] == 0.091 for a in anchors))
            self.assertTrue(all(a["x_end"] == 0.960 for a in anchors))

        keyboard = next(p for p in presets.values() if p["part"] == "keyboard")
        guitar = next(p for p in presets.values() if p["part"] == "guitar")
        self.assertEqual(max(a["page"] for a in keyboard["anchors"]), 4)
        self.assertEqual(max(a["page"] for a in guitar["anchors"]), 8)


if __name__ == "__main__":
    unittest.main()
