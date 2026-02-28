#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

void ghostty_fuzz_parser(const uint8_t *input, size_t input_len);

int main(int argc, char **argv) {
    uint8_t buf[4096];
    size_t len = 0;
    FILE *f = stdin;

    if (argc > 1) {
        f = fopen(argv[1], "rb");
        if (f == NULL) {
            return 0;
        }
    }

    len = fread(buf, 1, sizeof(buf), f);

    if (argc > 1) {
        fclose(f);
    }

    ghostty_fuzz_parser(buf, len);
    return 0;
}
