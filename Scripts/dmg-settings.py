import os

app_path = defines["app"]
app_name = os.path.basename(app_path)

files = [app_path]
symlinks = {"Applications": "/Applications"}

background = defines["background"]
window_rect = ((200, 120), (660, 420))
icon_size = 112
text_size = 13
icon_locations = {
    app_name: (125, 235),
    "Applications": (535, 235),
}

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
label_pos = "bottom"

format = "UDZO"
filesystem = "HFS+"
