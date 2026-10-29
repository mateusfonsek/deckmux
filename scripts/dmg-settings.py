# dmgbuild settings for the Deckmux disk image: the window with the Deckmux
# background (Resources/dmg/background.tiff, 1x + 2x), the app on the left,
# Applications on the right, and the app icon as the volume icon.
# Used by scripts/package-release.sh:
#   dmgbuild -s scripts/dmg-settings.py -D app=<Deckmux.app> -D background=<tiff> <volume name> <out.dmg>
import os

app = defines["app"]  # noqa: F821 (dmgbuild injects `defines`)

format = "UDZO"
filesystem = "HFS+"
files = [app]
# Named like the background's hint (the interface is in Portuguese).
symlinks = {"Aplicativos": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")
background = defines["background"]  # noqa: F821

# 660 x 400 window, matching the background; icons centered on its arrow.
window_rect = ((200, 160), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {
    os.path.basename(app): (175, 196),
    "Aplicativos": (485, 196),
}
hide_extension = [os.path.basename(app)]
