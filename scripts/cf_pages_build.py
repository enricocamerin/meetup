#!/usr/bin/env python3
"""Build the site for Cloudflare Pages: copy only the public files into dist/.

Cloudflare Pages settings: Framework preset "None", Build command `python3 scripts/cf_pages_build.py`,
Build output directory `dist`, production branch `main`. Nothing else (supabase/, README, CLAUDE.md,
scripts/) reaches the website. `_headers` is read by Cloudflare Pages (same format as Netlify).
"""
import os, shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "dist")
PUBLIC = ["index.html", "robots.txt", "_headers"]

shutil.rmtree(OUT, ignore_errors=True)
os.makedirs(OUT)
for f in PUBLIC:
    shutil.copy2(os.path.join(ROOT, f), os.path.join(OUT, f))
print("dist/:", ", ".join(sorted(os.listdir(OUT))))
