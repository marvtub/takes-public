"""The blog article: posts/article.md, markdown with the blog's components, front matter title,
description, category and slug."""
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


@unittest.skipUnless(t.BLOG, "the blog is private: the public copy has no article platform")
class ArticleTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        self.s = os.path.join(self.root, "P", "2026-10-04-a")
        os.makedirs(self.s)
        t.write_meta(self.s, {"title": "A", "createdAt": "2026-10-04T10:00:00Z", "takes": []})

    def tearDown(self):
        shutil.rmtree(self.root)
        os.environ.pop("TAKES_ROOT", None)

    def test_no_article_without_blog(self):
        """With the blog off (the public copy) the platform is gone from the tools and get_session."""
        t.PLATFORMS.pop("article")
        try:
            with self.assertRaises(ValueError):
                t.platform_of({"platform": "blog"})
        finally:
            t.PLATFORMS["article"] = dict(name="Article", post=os.path.join("posts", "article.md"),
                                          dir=os.path.join("posts", "article"), suffix="article", limit=200000)

    def test_write_article_with_head(self):
        out = t.t_set_post({"session": self.s, "platform": "blog", "title": "How I Ship Without Reading Code",
                            "description": "One PR, every time.", "category": "Tech",
                            "text": "## Why\n\nBecause.\n\n<Callout type=\"tip\">Do it.</Callout>\n"})
        self.assertEqual(out["platform"], "Article")
        self.assertEqual(out["slug"], "how-i-ship-without-reading-code")
        self.assertEqual(out["components"], ["Callout"])
        self.assertIn("blog", out["note"])
        fm, body = t.post_file(self.s, "article")
        self.assertEqual(fm["category"], "Tech")
        self.assertEqual(fm["description"], "One PR, every time.")
        self.assertTrue(body.startswith("## Why"))
        self.assertTrue(os.path.exists(os.path.join(self.s, "posts", "article.md")))
        self.assertEqual(t.t_get_session({"session": self.s})["article"]["title"], "How I Ship Without Reading Code")

    def test_head_fields_only_for_articles(self):
        with self.assertRaises(ValueError):
            t.t_set_post({"session": self.s, "platform": "linkedin", "text": "x", "category": "Tech"})
        with self.assertRaises(ValueError):
            t.t_set_post({"session": self.s, "platform": "article", "text": "x", "category": "Food"})

    def test_slug_is_cleaned_and_publish_action_names_the_blog(self):
        t.t_set_post({"session": self.s, "platform": "article", "text": "x", "slug": "My Pi Setup!"})
        fm, _ = t.post_file(self.s, "article")
        self.assertEqual(fm["slug"], "my-pi-setup")
        t.t_set_post_status({"session": self.s, "platform": "article", "status": "ready"})
        self.assertIn("the blog", t.read_post(self.s, "article")["action"])


if __name__ == "__main__":
    unittest.main()
