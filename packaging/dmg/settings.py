# dmgbuild settings for Latchkey's disk image (scripts/make-dmg.sh, from scripts/release.sh). dmgbuild writes the
# window's layout straight into the image, so building never opens a Finder window.
# Pass -D app=<Latchkey.app> -D here=<this folder>.
import os.path

app = defines["app"]  # noqa: F821  (dmgbuild provides `defines`)
here = defines["here"]  # noqa: F821  (this folder)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = ["Latchkey.app"]

# 640×400 points; background.tiff is drawn by scripts/make-installer-art.swift at this size, with the arrow between
# the two icons below.
background = os.path.join(here, "background.tiff")
window_rect = ((200, 140), (640, 400))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
icon_size = 128
text_size = 13
arrange_by = None
icon_locations = {
    "Latchkey.app": (170, 210),
    "Applications": (470, 210),
}
