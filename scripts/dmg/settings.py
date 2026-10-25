# dmgbuild settings for the install window, used by scripts/release.sh:
#
#   python3 -m dmgbuild -s scripts/dmg/settings.py -D app=<ClipApp.app> \
#     -D background=scripts/dmg/background.tiff ClipApp <out.dmg>
#
# dmgbuild writes the window layout into .DS_Store itself, without Finder or
# AppleScript. The background is the 660x400 picture with its 2x version in
# one tiff (tiffutil -cathidpicheck); the icon positions sit on its two glows.
import os.path

app = defines["app"]
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"

files = [app]
symlinks = {"Applications": "/Applications"}

background = defines["background"]
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 112
text_size = 12
label_pos = "bottom"
# Kept where they are placed, on one line.
arrange_by = None
icon_locations = {
    app_name: (165, 200),
    "Applications": (495, 200),
}
