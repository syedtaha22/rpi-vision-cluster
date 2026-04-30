#!/usr/bin/env python3
"""
mat_to_png.py — BSDS500 ground truth .mat → grayscale PNG converter.

Pure Python stdlib only (struct, zlib, os, sys).
Handles MATLAB Level-5 .mat files with OR without zlib compression.
Correctly recurses into CELL and STRUCT arrays to find Boundaries matrices.

Usage:
  python3 mat_to_png.py <input.mat> <output.png>
  python3 mat_to_png.py --batch <gt_dir> <out_dir>

Output: grayscale PNG, 255 = edge, 0 = background,
        averaged over all human annotators, threshold = 0.5.
"""

import os
import sys
import struct
import zlib


# ── PNG writer (stdlib only) ───────────────────────────────────────────────────

def _png_chunk(tag, data):
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)


def write_gray_png(path, pixels, width, height):
    """Write a grayscale PNG from a flat list/bytes of uint8 pixel values."""
    raw = bytearray()
    for r in range(height):
        raw += b'\x00'  # filter byte: None
        raw += bytes(pixels[r * width:(r + 1) * width])
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(_png_chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 0, 0, 0, 0)))
        f.write(_png_chunk(b'IDAT', zlib.compress(bytes(raw), 6)))
        f.write(_png_chunk(b'IEND', b''))


# ── MATLAB Level-5 parser ──────────────────────────────────────────────────────

# Element type constants
_MI_COMPR  = 15   # miCOMPRESSED
_MI_MATRIX = 14   # miMATRIX

# Array class constants
_MX_CELL   = 1    # cell array   — recurse into elements
_MX_STRUCT = 2    # struct array — recurse into field values
_MX_DOUBLE = 6    # mxDOUBLE_CLASS
_MX_UINT8  = 9    # mxUINT8_CLASS (MATLAB Level-5 uses 9, not 8)
_MX_UINT16 = 11   # mxUINT16_CLASS (Segmentation field — skip)


def _read_elem(buf, pos):
    """
    Parse one MAT data element at buf[pos].
    Returns (elem_type, content_bytes, next_pos).
    Handles Small Data Elements (SDE) where type+size are packed in the tag word.
    Returns (None, None, len(buf)) on any error.
    """
    if pos + 8 > len(buf):
        return None, None, len(buf)

    tag, = struct.unpack_from('<I', buf, pos)
    sz,  = struct.unpack_from('<I', buf, pos + 4)

    # Small Data Element: high 16 bits of tag word carry the data byte-count
    if tag >> 16:
        sde_type = tag & 0xFFFF
        sde_size = (tag >> 16) & 0xFFFF
        content  = buf[pos + 4: pos + 4 + sde_size]
        return sde_type, content, pos + 8   # SDEs are always 8 bytes total

    if sz == 0:
        return tag, b'', pos + 8

    content = buf[pos + 8: pos + 8 + sz]
    padded  = sz + (-sz % 8)               # round up to 8-byte boundary
    return tag, content, pos + 8 + padded


def _extract_2d_arrays(buf):
    """
    Walk a buffer of concatenated MAT elements.
    Returns a list of (rows, cols, flat_pixel_list_0_or_1) for every
    2D uint8/double array with image-like dimensions found anywhere
    in the tree (recursing into CELL/STRUCT and decompressing miCOMPRESSED).
    """
    results = []
    pos   = 0
    guard = 0
    while pos < len(buf) and guard < 50000:
        guard += 1
        etype, content, next_pos = _read_elem(buf, pos)
        if etype is None:
            break

        if etype == _MI_COMPR:
            # Decompress and recurse — this handles all Kaggle BSDS500 files
            try:
                results.extend(_extract_2d_arrays(zlib.decompress(content)))
            except Exception:
                pass

        elif etype == _MI_MATRIX and content:
            results.extend(_parse_matrix(content))

        pos = next_pos
    return results


def _parse_matrix(buf):
    """
    Parse the *content* of a miMATRIX element (everything after the 8-byte tag/size).
    Returns a list of (rows, cols, pixels_0_or_1).

    For numeric (uint8 / double) matrices with image dimensions → extract pixels.
    For CELL / STRUCT matrices → recurse into the nested element stream.
    """
    try:
        pos = 0

        # 1. Array flags sub-element
        ft, fc, pos = _read_elem(buf, pos)
        if ft is None or len(fc) < 4:
            return []
        array_class = struct.unpack_from('<I', fc, 0)[0] & 0xFF

        # 2. Dimensions sub-element
        dt, dc, pos = _read_elem(buf, pos)
        if dt is None:
            return []
        ndims = len(dc) // 4
        dims  = struct.unpack_from(f'<{ndims}i', dc) if ndims >= 2 else (0, 0)
        rows  = dims[0] if ndims >= 1 else 0
        cols  = dims[1] if ndims >= 2 else 0

        # 3. Array name sub-element (skip content)
        nt, nc, pos = _read_elem(buf, pos)
        if nt is None:
            return []

        # ── Numeric 2D array (the actual Boundaries matrix) ─────────────────
        if array_class in (_MX_UINT8, _MX_DOUBLE):
            if not (50 < rows < 2000 and 50 < cols < 2000):
                return []

            dat_t, dat_c, _ = _read_elem(buf, pos)
            if dat_t is None or not dat_c:
                return []

            total  = rows * cols
            pixels = [0] * total

            if array_class == _MX_UINT8:
                if len(dat_c) < total:
                    return []
                # MATLAB stores column-major → transpose to row-major
                for c in range(cols):
                    for r in range(rows):
                        pixels[r * cols + c] = dat_c[r + c * rows]

            else:  # double
                dcount = len(dat_c) // 8
                if dcount < total:
                    return []
                for c in range(cols):
                    for r in range(rows):
                        idx = r + c * rows
                        if idx < dcount:
                            val, = struct.unpack_from('<d', dat_c, idx * 8)
                            pixels[r * cols + c] = 1 if val > 0.5 else 0

            return [(rows, cols, pixels)]

        # ── CELL or STRUCT: recurse into the remaining element stream ────────
        # For STRUCT, the next two sub-elements are field-name-length and
        # field-names (both non-matrix types), so _extract_2d_arrays will
        # skip them automatically and find the nested miMATRIX field values.
        elif array_class in (_MX_CELL, _MX_STRUCT):
            return _extract_2d_arrays(buf[pos:])

        return []

    except Exception:
        return []


# ── Public API ─────────────────────────────────────────────────────────────────

def mat_to_png(mat_path, png_path):
    """
    Convert one BSDS500 .mat file to a binary edge PNG.
    Returns True on success, False on failure.
    """
    try:
        with open(mat_path, 'rb') as f:
            raw = f.read()
    except OSError as e:
        print(f'  [ERROR] Cannot open {mat_path}: {e}')
        return False

    if b'MATLAB 5.0' not in raw[:128]:
        print(f'  [ERROR] Not a MATLAB Level-5 file: {mat_path}')
        return False

    # The 128-byte file header is followed by the element stream
    arrays = _extract_2d_arrays(raw[128:])

    if not arrays:
        print(f'  [ERROR] No boundary data found in: {mat_path}')
        return False

    # Use shape of first found array as canonical; average matching annotators
    rows, cols = arrays[0][0], arrays[0][1]
    total = rows * cols
    avg   = [0.0] * total
    n     = 0
    for r, c, px in arrays:
        if r == rows and c == cols:
            for i in range(total):
                avg[i] += px[i]
            n += 1

    if n == 0:
        print(f'  [ERROR] No valid annotator data in: {mat_path}')
        return False

    binary = bytearray(255 if avg[i] / n >= 0.5 else 0 for i in range(total))
    write_gray_png(png_path, binary, cols, rows)
    print(f'  {os.path.basename(mat_path)} → {os.path.basename(png_path)}'
          f'  [{cols}×{rows}, {n} annotator(s)]')
    return True


# ── CLI ────────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    if sys.argv[1] == '--batch':
        if len(sys.argv) < 4:
            print(f'Usage: {sys.argv[0]} --batch <gt_dir> <out_dir>')
            sys.exit(1)
        gt_dir, out_dir = sys.argv[2], sys.argv[3]
        if not os.path.isdir(gt_dir):
            print(f'[ERROR] GT directory not found: {gt_dir}')
            sys.exit(1)
        os.makedirs(out_dir, exist_ok=True)
        ok = fail = 0
        for fn in sorted(os.listdir(gt_dir)):
            if not fn.endswith('.mat'):
                continue
            stem = os.path.splitext(fn)[0]
            if mat_to_png(os.path.join(gt_dir, fn),
                          os.path.join(out_dir, stem + '_gt.png')):
                ok += 1
            else:
                fail += 1
        print(f'\nBatch complete: {ok} converted, {fail} failed')
        print(f'Output PNGs in: {out_dir}')
        sys.exit(1 if fail else 0)

    else:
        sys.exit(0 if mat_to_png(sys.argv[1], sys.argv[2]) else 1)


if __name__ == '__main__':
    main()
