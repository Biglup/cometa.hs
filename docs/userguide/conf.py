"""Narrative documentation; builds independently of the native library."""

project = "Cometa.hs"
author = "Biglup Labs"
copyright = "2026, Biglup Labs"
release = "0.1.0.0-dev"
version = release
extensions = ["myst_parser", "sphinx_immaterial"]
source_suffix = {".md": "markdown"}
root_doc = "index"
exclude_patterns = ["_build"]
nitpicky = True
highlight_language = "haskell"
html_theme = "sphinx_immaterial"
html_title = "Cometa.hs"
html_logo = "../../assets/cometa_hs.png"
html_static_path = ["_static"]
html_css_files = ["custom.css"]
html_theme_options = {
    "repo_url": "https://github.com/Biglup/cometa.hs",
    "repo_name": "cometa.hs",
    "edit_uri": "edit/main/docs/userguide/",
    "icon": {"repo": "fontawesome/brands/github"},
    "font": {"text": "Roboto", "code": "Roboto Mono"},
    "features": ["navigation.sections", "navigation.top", "search.share", "toc.follow"],
    "palette": [
        {
            "media": "(prefers-color-scheme: light)",
            "scheme": "default",
            "primary": "white",
            "accent": "deep-purple",
            "toggle": {"icon": "material/lightbulb-outline", "name": "Switch to dark mode"},
        },
        {
            "media": "(prefers-color-scheme: dark)",
            "scheme": "slate",
            "primary": "white",
            "accent": "purple",
            "toggle": {"icon": "material/lightbulb", "name": "Switch to light mode"},
        },
    ],
}
