"""벤치마크의 원본 png 한 장을 만든다.

`scripts/bench_skia.ps1`이 부른다. 만드는 것은 4000x7000 RGBA8 (unpremul) png다 —
이 저장소가 좇는 지연이 그 크기의 cubic 축소에서 나온다.

**Skia를 쓰지 않는 것이 요점이다.** 맞대어 볼 두 빌드가 같은 바이트를 디코딩해야
하는데, 원본을 어느 한쪽으로 인코딩하면 그 전제가 "먼저 돈 쪽이 만든 것"이라는
조건에 매달린다. 표준 라이브러리의 zlib만으로 만들면 그런 조건이 없다.

(png 인코더를 Skia에서 쓰지 못하는 실제 사정도 있다. 이 저장소의 args는 rust png
갈래이고 skia_use_rust_png_encode = true인데, Skia 152의 `:skia` component는
`:png_encode_rust`를 deps에 넣지 않는다 — 그 target을 끌어오는 자리가 legacy SVG
factory를 위한 `:xml` 하나뿐이고 이 구성은 그것을 끈다. 그래서 SkPngRustEncoder는
두 도구사슬 모두에서 아카이브에 없다. docs/skia-build.md 5.5에 적어 두었다.)

내용을 이렇게 고른 이유:
  - 부드러운 경사가 cubic 재추출에 실제로 일을 시키고 png가 터무니없이 커지지 않게
    한다.
  - 왼쪽 0에서 오른쪽 255까지 훑는 알파가, 축소가 프리멀티 알파를 어떻게 다루는지를
    결과 픽셀에 남긴다.
  - 세로 격자와 가로 띠가 고주파다. 재추출이 뭉개지거나 반 픽셀 어긋나면 여기서
    드러난다.
"""

import argparse
import struct
import zlib

WIDTH = 4000
HEIGHT = 7000
GRID_PERIOD = 97   # 세로 격자
GRID_WIDTH = 3
BAND_PERIOD = 89   # 가로 띠
BAND_WIDTH = 3


def chunk(tag, payload):
    return (struct.pack('>I', len(payload)) + tag + payload +
            struct.pack('>I', zlib.crc32(tag + payload) & 0xFFFFFFFF))


def build_row_template():
    """x에만 달린 채널을 미리 깐다. R과 G는 행마다 통째로 덮어쓴다."""
    row = bytearray(WIDTH * 4)
    for x in range(WIDTH):
        ramp = (x * 255) // (WIDTH - 1)
        row[x * 4 + 2] = 255 - ramp   # B
        row[x * 4 + 3] = ramp         # A
    return row


def build_red_plane():
    """R 한 판이다. 경사와 격자 위에 결정적인 잔무늬를 얹는다.

    잔무늬가 있어야 행마다 바이트가 갈려 png가 실제 사진만 한 부피로 압축된다.
    잔무늬 없이는 zlib이 행 전체를 되풀이로 접어 1.4 MB짜리가 나오는데, 그것으로
    잰 디코딩 시간은 실제와 멀다.
    """
    plane = bytearray(WIDTH)
    state = 0x2545F491
    for x in range(WIDTH):
        ramp = (x * 255) // (WIDTH - 1)
        value = 255 - ramp if (x % GRID_PERIOD) < GRID_WIDTH else ramp
        # xorshift32. 표준 라이브러리의 난수와 달리 판번에 매이지 않는다.
        state ^= (state << 13) & 0xFFFFFFFF
        state ^= state >> 17
        state ^= (state << 5) & 0xFFFFFFFF
        plane[x] = min(255, max(0, value + (state & 7) - 3))
    return bytes(plane)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', help='png를 쓸 경로')
    arguments = parser.parse_args()

    template = build_row_template()
    banded = bytearray(template)
    # 가로 띠는 B를 뒤집는다. 행 단위로 통째로 갈리므로 판 하나를 더 떠 두면 된다.
    banded[2::4] = bytes(255 - value for value in template[2::4])
    red = build_red_plane()

    raw = bytearray()
    for y in range(HEIGHT):
        row = banded if (y % BAND_PERIOD) < BAND_WIDTH else template
        line = bytearray(row)
        # R 판을 행마다 다른 만큼 돌려 얹는다. 사선 결이 생기고, 같은 행이 두 번
        # 나오지 않는다. 자르고 붙이는 것은 C 쪽에서 도는 연산이라 값이 싸다.
        shift = (y * 37) % WIDTH
        line[0::4] = red[shift:] + red[:shift]
        line[1::4] = bytes([(y * 255) // (HEIGHT - 1)]) * WIDTH   # G
        raw += b'\x00'      # filter type 0 (None)
        raw += line

    header = struct.pack('>IIBBBBB', WIDTH, HEIGHT, 8, 6, 0, 0, 0)  # 8-bit RGBA
    with open(arguments.output, 'wb') as output:
        output.write(b'\x89PNG\r\n\x1a\n')
        output.write(chunk(b'IHDR', header))
        output.write(chunk(b'IDAT', zlib.compress(bytes(raw), 6)))
        output.write(chunk(b'IEND', b''))


if __name__ == '__main__':
    main()
