application = defines["app"]  # noqa: F821
arrow = defines["arrow"]  # noqa: F821
arrow_item = "\u2063.tiff"

format = "UDZO"
filesystem = "HFS+"
compression_level = 9

files = [
    (application, "Current.app"),
    (arrow, arrow_item),
]
symlinks = {"Applications": "/Applications"}
hide_extensions = [arrow_item]

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
background = None
window_rect = ((200, 100000), (660, 400))
default_view = "icon-view"
show_icon_preview = True
include_icon_view_settings = True

arrange_by = None
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 14
icon_size = 112
icon_locations = {
    "Current.app": (160, 170),
    arrow_item: (330, 170),
    "Applications": (500, 170),
}
