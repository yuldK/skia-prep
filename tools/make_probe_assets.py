"""tools/feature_probe.cpp가 쓰는 시험 이미지를 C++ 헤더로 낸다.

probe가 파일을 읽지 않고 실행 파일 하나로 돌게 하려는 것이다 — Android에서는
adb로 실행 파일 하나만 올리면 된다. 이미지는 작고(모두 합쳐 수 KB) 판정이 쉬운
모양이다: 왼쪽 절반이 빨강, 오른쪽 절반이 파랑.

만드는 데 Pillow(AVIF 지원이 든 11 이상)가 필요하다. 소비자도 빌드도 이 스크립트를
부르지 않는다. 결과 헤더(tools/probe_assets.h)를 저장소가 들고 있다.

    python tools/make_probe_assets.py
"""
import io
import pathlib

from PIL import Image, features

RED = (220, 20, 30)
BLUE = (20, 40, 220)
FRAMES = [(220, 20, 30), (20, 200, 40), (20, 40, 220)]


def halves(size):
    image = Image.new('RGB', (size, size), BLUE)
    image.paste(Image.new('RGB', (size // 2, size), RED), (0, 0))
    return image


def encode(image, fmt, **options):
    buffer = io.BytesIO()
    image.save(buffer, fmt, **options)
    return buffer.getvalue()


def main():
    if not features.check('avif'):
        raise SystemExit('This Pillow cannot write AVIF. Install Pillow 11 or newer.')

    assets = {
        'kPng': encode(halves(16), 'PNG'),
        'kJpeg': encode(halves(16), 'JPEG', quality=95, subsampling=0),
        'kWebp': encode(halves(16), 'WEBP', lossless=True),
        'kAvifStill': encode(halves(32), 'AVIF', quality=95, subsampling='4:4:4'),
        'kAvifAnimated': encode(
            Image.new('RGB', (32, 32), FRAMES[0]), 'AVIF', quality=95, subsampling='4:4:4',
            save_all=True,
            append_images=[Image.new('RGB', (32, 32), color) for color in FRAMES[1:]],
            duration=100, loop=0),
    }

    lines = [
        '// tools/make_probe_assets.py가 만든 파일이다. 손으로 고치지 않는다.',
        '// 왼쪽 절반 빨강 {0}, 오른쪽 절반 파랑 {1}. 애니메이션 AVIF는 32x32 단색 세 프레임',
        '// {0}, 프레임마다 100 ms.',
        '#pragma once',
        '',
        '#include <cstdint>',
        '',
        'namespace probe_assets {',
        '',
    ]
    lines[1] = lines[1].format(RED, BLUE)
    lines[2] = lines[2].format(', '.join(str(color) for color in FRAMES))
    for name, data in assets.items():
        lines.append('inline constexpr uint8_t {0}[] = {{'.format(name))
        for start in range(0, len(data), 16):
            chunk = data[start:start + 16]
            lines.append('    ' + ', '.join('0x{0:02x}'.format(byte) for byte in chunk) + ',')
        lines.append('};')
        lines.append('')
    lines.append('}  // namespace probe_assets')
    lines.append('')

    target = pathlib.Path(__file__).with_name('probe_assets.h')
    target.write_bytes('\r\n'.join(lines).encode('utf-8'))
    for name, data in assets.items():
        print('{0:14} {1:6} bytes'.format(name, len(data)))
    print('wrote', target)


if __name__ == '__main__':
    main()
