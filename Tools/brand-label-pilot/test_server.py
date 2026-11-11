import unittest
from PIL import Image
from server import Pilot, PilotError, crop_box, encode_image, decode_image, ocr_readings


class PilotTests(unittest.TestCase):
    def test_ocr_timeout_keeps_last_complete_rotation(self):
        self.assertEqual(ocr_readings(b'{"readings":[]}\n{"readings":[{"text":"fixture"}]}\n{"readings":['), [{"text": "fixture"}])

    def test_crop_uses_top_left_pixels_with_padding_and_clamps_edges(self):
        self.assertEqual(crop_box({"x": .25, "y": .1, "width": .5, "height": .3}, (100, 200)), (17, 12, 83, 88))
        self.assertEqual(crop_box({"x": 0, "y": 0, "width": 1, "height": 1}, (100, 200)), (0, 0, 100, 200))
        for box in [dict(x=-.1, y=0, width=.5, height=.5), dict(x=0, y=0, width=float("nan"), height=.5),
                    dict(x=.8, y=0, width=.5, height=.5)]:
            with self.assertRaises(PilotError):
                crop_box(box, (100, 200))

    def test_exif_orientation_is_applied_before_normalized_crop(self):
        image = Image.new("RGB", (100, 200))
        image.getexif()[274] = 6
        oriented, data_url = encode_image(image)
        self.assertEqual(oriented.size, (200, 100))
        self.assertEqual(decode_image(data_url).size, (200, 100))

    def test_pipeline_reads_only_newly_cropped_pixels_and_never_passes_brand_guesses(self):
        image = Image.new("RGB", (200, 300), (230, 230, 230))
        _, data_url = encode_image(image)
        calls = []
        pilot = object.__new__(Pilot)

        def call(path, photos):
            calls.append((path, photos))
            if path == "brand-label-regions":
                return {"regions": [{"photoId": "source", "kind": "neck_print",
                    "box": dict(x=.25, y=.1, width=.5, height=.3)}]}
            return {"readings": [{"photoId": "label-crop-1", "text": "fixture label", "legibility": "partial"}], "brand": None}

        pilot.call = call
        pilot.ocr = lambda _: [{"rotationDegrees": 45, "text": "fixture label", "confidence": .9}]
        result = pilot.run({"photos": [{"id": "source", "imageDataUrl": data_url}]})
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[1][0], "brand-label-readings")
        self.assertEqual(calls[1][1][0]["role"], "label")
        self.assertEqual(calls[1][1][0]["ocrText"], "45°: fixture label")
        self.assertNotEqual(calls[1][1][0]["imageDataUrl"], calls[0][1][0]["imageDataUrl"])
        self.assertEqual(decode_image(calls[1][1][0]["imageDataUrl"]).size, (116, 106))
        self.assertEqual(result["crops"][0]["sourcePhotoId"], "source")

    def test_no_label_does_not_send_empty_crop_request(self):
        _, data_url = encode_image(Image.new("RGB", (100, 100)))
        calls = []
        pilot = object.__new__(Pilot)
        pilot.call = lambda path, photos: calls.append(path) or {"regions": []}
        result = pilot.run({"photos": [{"id": "source", "imageDataUrl": data_url}]})
        self.assertEqual(calls, ["brand-label-regions"])
        self.assertEqual(result["status"], "no_label_region")
        self.assertIsNone(result["brand"])


if __name__ == "__main__":
    unittest.main()
