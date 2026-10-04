"""phone_videos: AirDropped or iPhone videos in a folder, with the newest sessions to match them to."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"


def clip(path, *meta):
    args = [FFMPEG, "-v", "error", "-f", "lavfi", "-i", "color=c=black:s=64x64:d=1"]
    for m in meta:
        args += ["-metadata", m]
    subprocess.run(args + ["-movflags", "use_metadata_tags", "-y", path], check=True)


class PhoneVideos(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        s = os.path.join(self.root, "Proj", "2026-09-30-ai-pay")
        os.makedirs(s)
        with open(os.path.join(s, "session.json"), "w") as f:
            json.dump({"title": "AI Pay", "createdAt": "2026-09-30T10:00:00Z", "takes": []}, f)
        with open(os.path.join(s, "script.md"), "w") as f:
            f.write("Your agent can pay now.\n\nHere is how.")
        self.dl = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.root)
        shutil.rmtree(self.dl)
        os.environ.pop("TAKES_ROOT", None)

    def test_finds_airdrop_and_iphone_videos_only(self):
        clip(os.path.join(self.dl, "IMG_0001.MOV"), "com.apple.quicktime.model=iPhone 17 Pro",
             "com.apple.quicktime.creationdate=2026-09-30T08:00:00-0700")
        dropped = os.path.join(self.dl, "IMG_0002.MOV")
        clip(dropped)
        subprocess.run(["xattr", "-w", "com.apple.quarantine", "0083;66fa0000;sharingd;", dropped], check=True)
        clip(os.path.join(self.dl, "render-v3.mp4"))
        with open(os.path.join(self.dl, "notes.txt"), "w") as f:
            f.write("x")
        r = t.t_phone_videos({"folder": self.dl})
        names = sorted(v["name"] for v in r["videos"])
        self.assertEqual(names, ["IMG_0001.MOV", "IMG_0002.MOV"])
        phone = next(v for v in r["videos"] if v["name"] == "IMG_0001.MOV")
        self.assertEqual(phone["device"], "iPhone 17 Pro")
        self.assertFalse(phone["airdrop"])
        self.assertTrue(next(v for v in r["videos"] if v["name"] == "IMG_0002.MOV")["airdrop"])
        self.assertEqual(r["recent_sessions"][0]["script_start"], "Your agent can pay now. Here is how.")
        self.assertEqual(len(t.t_phone_videos({"folder": self.dl, "all": True})["videos"]), 3)


if __name__ == "__main__":
    unittest.main()
