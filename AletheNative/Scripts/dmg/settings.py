# dmgbuild settings for the Alethe installer window. Driven by Scripts/make-dmg.sh,
# which passes -D app=<path to Alethe.app> and -D dmg_dir=<this folder>. Icon positions must match the arrow and
# panel drawn by Scripts/dmg/make-background.py.
import os.path

app = defines["app"]  # noqa: F821 (injected by dmgbuild)
here = defines["dmg_dir"]  # noqa: F821

format = "ULFO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")
# background@2x.png next to it is picked up for Retina.
background = os.path.join(here, "background.png")

# Frame size: the 400pt-tall background plus the 28pt title bar.
window_rect = ((200, 160), (640, 428))
default_view = "icon-view"
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_tab_view = False
show_pathbar = False
show_icon_preview = False
include_icon_view_settings = True
arrange_by = None
icon_size = 96
text_size = 12
icon_locations = {
    os.path.basename(app): (170, 190),
    "Applications": (470, 190),
}
