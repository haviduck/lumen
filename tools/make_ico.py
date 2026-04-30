"""
Convert two PNG sources into a single multi-size Windows ICO file.
- small_source → used for 16, 24, 32 px (title bar icon)
- big_source   → used for 48, 64, 128, 256 px (taskbar/start menu icon)
"""
import io
import struct
import sys
from PIL import Image


def _prepare(path):
    """Open, crop to main circle, trim, pad to square."""
    img = Image.open(path).convert('RGBA')
    w, h = img.size
    # Crop wide banner to left square
    if w > h * 1.1:
        img = img.crop((0, 0, h, h))
    bbox = img.getbbox()
    if bbox:
        img = img.crop(bbox)
    w, h = img.size
    side = max(w, h)
    sq = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    sq.paste(img, ((side - w) // 2, (side - h) // 2))
    return sq


def _make_bmp_entry(img, size):
    """Resize img to (size, size) and return raw PNG bytes for the ICO entry."""
    resized = img.resize((size, size), Image.LANCZOS)
    buf = io.BytesIO()
    resized.save(buf, format='PNG')
    return buf.getvalue()


def build_ico(small_img, big_img, out_path):
    """
    Build a multi-resolution ICO manually so we can use different source
    images for small vs large sizes.
    """
    # (size, source_image)
    entries = [
        (16, small_img),
        (24, small_img),
        (32, small_img),
        (48, big_img),
        (64, big_img),
        (128, big_img),
        (256, big_img),
    ]

    png_data = []
    for size, src in entries:
        png_data.append(_make_bmp_entry(src, size))

    num = len(entries)
    # ICO header: 6 bytes  |  each dir entry: 16 bytes
    header_size = 6 + num * 16
    # ICO header
    header = struct.pack('<HHH', 0, 1, num)  # reserved, type=1(ico), count

    dir_entries = b''
    data_block = b''
    offset = header_size
    for i, (size, _) in enumerate(entries):
        d = png_data[i]
        w = 0 if size == 256 else size
        h = 0 if size == 256 else size
        dir_entries += struct.pack(
            '<BBBBHHII',
            w, h,         # width, height (0 = 256)
            0, 0,         # color count, reserved
            1, 32,        # planes, bpp
            len(d),       # data size
            offset,       # offset from start of file
        )
        offset += len(d)
        data_block += d

    with open(out_path, 'wb') as f:
        f.write(header + dir_entries + data_block)

    import os
    print(f'Created {out_path} ({os.path.getsize(out_path):,} bytes)')
    print(f'  Small source -> 16, 24, 32 px')
    print(f'  Big source   -> 48, 64, 128, 256 px')


def main():
    if len(sys.argv) < 3:
        print('Usage: python make_ico.py <small.png> <big.png> [output.ico]')
        sys.exit(1)

    small_path = sys.argv[1]
    big_path = sys.argv[2]
    out = sys.argv[3] if len(sys.argv) > 3 else 'app_icon.ico'

    small_img = _prepare(small_path)
    big_img = _prepare(big_path)

    print(f'Small source: {small_path} -> {small_img.size}')
    print(f'Big source:   {big_path} -> {big_img.size}')

    build_ico(small_img, big_img, out)


if __name__ == '__main__':
    main()
