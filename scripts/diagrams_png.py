"""Export full-diagram PNGs (light and dark) from rendered diagram HTML files.

Uses the locally installed Chrome through Playwright, so no browser download is needed:

    uv run --with playwright python scripts/diagrams_png.py build/diagrams/archify/*.html
"""

from __future__ import annotations

import argparse
from pathlib import Path

from playwright.sync_api import sync_playwright

SCHEMES = ("light", "dark")
# Viewer chrome that floats over the diagram and would otherwise be captured in the PNG.
HIDE_VIEWER_CHROME = """
[aria-label="Diagram exploration actions"], [aria-label="Diagram view controls"],
[aria-label="Diagram actions"], .toolbar { display: none !important; }
"""


def export_pngs(html_files: list[Path], selector: str, scale: float) -> list[Path]:
    """Write ``<name>.light.png`` and ``<name>.dark.png`` next to each HTML file."""
    written: list[Path] = []
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel="chrome")
        try:
            for html in html_files:
                for scheme in SCHEMES:
                    page = browser.new_page(
                        viewport={"width": 1600, "height": 1000},
                        device_scale_factor=scale,
                        color_scheme=scheme,  # type: ignore[arg-type]
                    )
                    try:
                        page.goto(html.resolve().as_uri())
                        page.wait_for_selector(selector)
                        page.add_style_tag(content=HIDE_VIEWER_CHROME)
                        target = html.with_suffix(f".{scheme}.png")
                        page.locator(selector).first.screenshot(path=str(target))
                        written.append(target)
                    finally:
                        page.close()
        finally:
            browser.close()
    return written


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("html", nargs="+", type=Path, help="rendered diagram HTML files")
    parser.add_argument("--selector", default="svg[role=img]", help="element to capture")
    parser.add_argument("--scale", type=float, default=2.0, help="device scale factor")
    args = parser.parse_args()
    for path in export_pngs(args.html, args.selector, args.scale):
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
