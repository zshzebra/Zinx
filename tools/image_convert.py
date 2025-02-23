from PIL import Image
import sys

def main():
    if (not len(sys.argv) == 2):
        print("Usage:\n\tpython3 image_convert.py path/to/file")
        return
    
    image = Image.open(sys.argv[1])

    pixels = list(image.getdata())
    width, height = image.size

    pixels = [
            (p[0] << 16) |
            (p[1] << 8) |
            p[2] for p in pixels
            ]
    
    pixels = [hex(p)[2:].upper() for p in pixels]

    out = f"pub const width: u64 = {str(width)};\npub const height: u64 = {str(height)};\npub const data = [_]u32{{{',\n     '.join(['0x' + p for p in pixels])}}};";
    with open(''.join(sys.argv[1].split('.')[:-1]) + '.zig', 'w') as f:
        f.write(out)

if __name__ == "__main__":
    main()
