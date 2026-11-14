#!/usr/bin/env python3
"""Fetch each known service's site icon into the app's asset catalog, as ServiceIcons/<Service>.imageset.

The app shows these beside services in the sidebar and makes no network request for them. Run this when a service is
added to Sources/LatchkeyCore/Services.swift (add it to SITES too), then review the images before committing.

  python3 scripts/fetch-service-icons.py            fetch every service that has no icon yet
  python3 scripts/fetch-service-icons.py --refresh  fetch them all again

Icons are read from the site's own <link rel="apple-touch-icon"> or <link rel="icon"> (largest PNG first), falling
back to /apple-touch-icon.png and /favicon.ico, and converted to 64x64 PNG with sips. Nothing else is fetched.
"""
import html.parser
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, 'App/Latchkey/Assets.xcassets/ServiceIcons')
MAX_BYTES = 2_000_000
UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15'

# Service name (as Services.swift spells it) -> the service's own site.
SITES = {
    'Algolia': 'https://www.algolia.com', 'Anthropic': 'https://www.anthropic.com', 'Apple': 'https://www.apple.com',
    'AWS': 'https://aws.amazon.com', 'Azure': 'https://azure.microsoft.com', 'Clerk': 'https://clerk.com',
    'Cloudflare': 'https://www.cloudflare.com', 'Convex': 'https://www.convex.dev', 'DigitalOcean': 'https://www.digitalocean.com',
    'Firebase': 'https://firebase.google.com', 'Fly': 'https://fly.io', 'GitHub': 'https://github.com',
    'GitLab': 'https://gitlab.com', 'Google': 'https://www.google.com', 'Linear': 'https://linear.app',
    'Mailgun': 'https://www.mailgun.com', 'MongoDB Atlas': 'https://www.mongodb.com', 'Neon': 'https://neon.tech',
    'Notion': 'https://www.notion.so', 'npm': 'https://docs.npmjs.com', 'OpenAI': 'https://openai.com',
    'PlanetScale': 'https://planetscale.com', 'PostHog': 'https://posthog.com', 'Pusher': 'https://pusher.com',
    'Railway': 'https://railway.com', 'Redis Cloud': 'https://redis.io', 'Render': 'https://dashboard.render.com',
    'Resend': 'https://resend.com', 'SendGrid': 'https://app.sendgrid.com', 'Sentry': 'https://sentry.io',
    'Slack': 'https://slack.com', 'Stripe': 'https://stripe.com', 'Supabase': 'https://supabase.com',
    'Turso': 'https://turso.tech', 'Twilio': 'https://www.twilio.com', 'Upstash': 'https://upstash.com',
    'Vercel': 'https://vercel.com',
}


def get(url):
    req = urllib.request.Request(url, headers={'User-Agent': UA})
    with urllib.request.urlopen(req, timeout=15) as r:
        if not r.geturl().startswith('https://'):
            raise ValueError('redirected off https')
        data = r.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise ValueError('too large')
        return data, r.headers.get_content_type(), r.geturl()


class Links(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.icons = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        rel = (a.get('rel') or '').lower().split()
        if tag == 'link' and a.get('href') and ('apple-touch-icon' in rel or 'icon' in rel):
            size = max([int(n) for n in re.findall(r'(\d+)x\d+', a.get('sizes') or '')] or [0])
            self.icons.append((a['href'], 'apple-touch-icon' in rel, size, (a.get('type') or '').lower()))


def candidates(site):
    out = []
    try:
        page, _, final = get(site)
        p = Links()
        p.feed(page.decode('utf-8', 'replace'))
        # Raster first (sips can't read SVG), then apple-touch-icon, then the largest declared size.
        ranked = sorted(p.icons, key=lambda i: (i[0].endswith('.svg') or 'svg' in i[3], not i[1], -i[2]))
        out += [urllib.parse.urljoin(final, h) for h, *_ in ranked]
    except Exception as e:
        print(f'    page: {e}')
    out += [urllib.parse.urljoin(site + '/', '/apple-touch-icon.png'), urllib.parse.urljoin(site + '/', '/favicon.ico')]
    return out


def to_png(data, dest):
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, 'icon')
        open(src, 'wb').write(data)
        out = os.path.join(tmp, 'icon.png')
        r = subprocess.run(['sips', '-s', 'format', 'png', '-Z', '64', src, '--out', out], capture_output=True)
        if r.returncode != 0 or not os.path.exists(out):
            return False
        w = subprocess.run(['sips', '-g', 'pixelWidth', out], capture_output=True, text=True).stdout
        if int(re.search(r'pixelWidth: (\d+)', w).group(1)) < 32:
            return False  # too small to look right at 20 points on a Retina screen
        shutil.copy(out, dest)
        return True


def main():
    refresh = '--refresh' in sys.argv
    os.makedirs(CATALOG, exist_ok=True)
    json.dump({'info': {'author': 'xcode', 'version': 1}, 'properties': {'provides-namespace': True}},
              open(os.path.join(CATALOG, 'Contents.json'), 'w'), indent=2)
    missing = []
    for name, site in sorted(SITES.items()):
        folder = os.path.join(CATALOG, f'{name}.imageset')
        if os.path.exists(folder) and not refresh:
            continue
        print(name)
        done = False
        for url in candidates(site):
            if url.endswith('.svg'):
                continue
            try:
                data, kind, _ = get(url)
            except Exception as e:
                print(f'    {url}: {e}')
                continue
            os.makedirs(folder, exist_ok=True)
            if to_png(data, os.path.join(folder, 'icon.png')):
                json.dump({'images': [{'filename': 'icon.png', 'idiom': 'universal'}], 'info': {'author': 'xcode', 'version': 1}},
                          open(os.path.join(folder, 'Contents.json'), 'w'), indent=2)
                print(f'    {url}')
                done = True
                break
        if not done:
            shutil.rmtree(folder, ignore_errors=True)
            missing.append(name)
    if missing:
        print('no usable icon:', ', '.join(missing))


if __name__ == '__main__':
    main()
