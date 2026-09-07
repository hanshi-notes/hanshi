#include <stddef.h>
#include <stdint.h>
int32_t hanshi_mermaid_render(const uint8_t *source, size_t length, float scale, uint8_t **output, size_t *output_length);
void hanshi_mermaid_free(uint8_t *bytes, size_t length);
