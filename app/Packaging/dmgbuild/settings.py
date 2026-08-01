application = defines["app"]  # noqa: F821
background = defines["background"]  # noqa: F821

format = "UDZO"
filesystem = "HFS+"
compression_level = 9

files = [(application, "Current.app")]
symlinks = {"Applications": "/Applications"}

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
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
    "Applications": (500, 170),
}
