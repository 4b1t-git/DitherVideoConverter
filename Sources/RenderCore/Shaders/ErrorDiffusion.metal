#include <metal_stdlib>
using namespace metal;

static void addError(device int *work, int width, int height, int x, int y, int value) {
    if (x >= 0 && x < width && y >= 0 && y < height) {
        work[y * width + x] += value;
    }
}

kernel void errorDiffusion(
    device const uchar *input [[buffer(0)]],
    device uchar *output [[buffer(1)]],
    device int *work [[buffer(2)]],
    constant uint &widthValue [[buffer(3)]],
    constant uint &heightValue [[buffer(4)]],
    constant uint &algorithm [[buffer(5)]],
    constant uint &sourceWidthValue [[buffer(6)]],
    constant uint &sourceHeightValue [[buffer(7)]],
    uint threadID [[thread_position_in_grid]]) {
    if (threadID != 0) return;
    int width = int(widthValue);
    int height = int(heightValue);
    int sourceWidth = int(sourceWidthValue);
    int sourceHeight = int(sourceHeightValue);
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            int sourceIndex = (y * sourceHeight / height) * sourceWidth
                + x * sourceWidth / width;
            work[y * width + x] = int(input[sourceIndex]) * 16;
        }
    }

    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            int index = y * width + x;
            int quantized = work[index] >= 128 * 16 ? 255 : 0;
            output[index] = uchar(quantized);
            int error = work[index] - quantized * 16;
            if (algorithm == 0) {
                int eighth = error / 8;
                addError(work, width, height, x + 1, y, eighth);
                addError(work, width, height, x + 2, y, eighth);
                addError(work, width, height, x - 1, y + 1, eighth);
                addError(work, width, height, x, y + 1, eighth);
                addError(work, width, height, x + 1, y + 1, eighth);
                addError(work, width, height, x, y + 2, eighth);
            } else {
                addError(work, width, height, x + 1, y, error * 7 / 16);
                addError(work, width, height, x - 1, y + 1, error * 3 / 16);
                addError(work, width, height, x, y + 1, error * 5 / 16);
                addError(work, width, height, x + 1, y + 1, error / 16);
            }
        }
    }
}
