#!/usr/bin/env python3
"""Add (or replace) one release's item in site/appcast.xml, the feed Latchkey's updater reads.

Called by scripts/release.sh with the output line of Sparkle's sign_update, e.g.
    sparkle:edSignature="..." length="12345"
"""
import argparse
import email.utils
import pathlib
import re
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPO = "https://github.com/zachshallbetter/latchkey"
ET.register_namespace("sparkle", SPARKLE)


def q(name):
    return f"{{{SPARKLE}}}{name}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appcast", type=pathlib.Path, required=True)
    parser.add_argument("--version", required=True, help="MARKETING_VERSION")
    parser.add_argument("--build", required=True, help="CURRENT_PROJECT_VERSION")
    parser.add_argument("--min-os", required=True, help="the app's deployment target")
    parser.add_argument("--signature", required=True, help="output of sign_update")
    args = parser.parse_args()
    signature = re.search(r'sparkle:edSignature="([^"]+)"', args.signature)
    length = re.search(r'length="(\d+)"', args.signature)
    if not signature or not length:
        parser.error("--signature must hold sparkle:edSignature and length from sign_update")

    if args.appcast.exists():
        tree = ET.parse(args.appcast)
        channel = tree.getroot().find("channel")
    else:
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "Latchkey"
        ET.SubElement(channel, "link").text = "https://latchkey.snackstud.io/"
        ET.SubElement(channel, "description").text = "Latchkey releases"
        tree = ET.ElementTree(root)
    for item in channel.findall("item"):
        if item.findtext(q("shortVersionString")) == args.version:
            channel.remove(item)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Latchkey {args.version}"
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    ET.SubElement(item, q("version")).text = args.build
    ET.SubElement(item, q("shortVersionString")).text = args.version
    ET.SubElement(item, q("minimumSystemVersion")).text = args.min_os
    ET.SubElement(item, q("releaseNotesLink")).text = f"{REPO}/blob/main/CHANGELOG.md"
    ET.SubElement(item, "enclosure", {
        "url": f"{REPO}/releases/download/v{args.version}/Latchkey-{args.version}.dmg",
        "length": length.group(1), "type": "application/octet-stream", q("edSignature"): signature.group(1)})
    first = next((i for i, child in enumerate(channel) if child.tag == "item"), len(channel))
    channel.insert(first, item)  # newest first
    ET.indent(tree, space="  ")
    args.appcast.parent.mkdir(parents=True, exist_ok=True)
    tree.write(args.appcast, encoding="utf-8", xml_declaration=True)
    args.appcast.write_text(args.appcast.read_text() + "\n")


if __name__ == "__main__":
    main()
