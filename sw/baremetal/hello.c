/*
 * hello.c -- the HYDRA CPU slot's first C program (the Baremetal-IDE lab's
 * "hello world", d03, for this chip)
 *
 * Prints through the putchar register, then computes three things a wrong
 * core gets wrong: an iterative Fibonacci (adds, branches), a CRC-32 of the
 * greeting (shifts, xors, loads), and a 64-bit multiply-divide check (the
 * M extension). main() returns a mix of all three, which crt0 writes to
 * TOHOST: the testbench compares it, and every register, with Sixfold's own
 * model, so the output is checked on the RTL, not only in the model.
 */
#include <stdint.h>
#include "hydra_cpu.h"

static const char greeting[] = "Hello from the HYDRA-130 CPU slot\n";

/* Wait while the UART's queue is full, then queue the byte. Sixfold's model
 * reads UART_STATUS as 0, so there it never waits; on the chip (a 16-byte
 * queue) it is what keeps a long printout whole. */
static void putc_wait(char ch) {
  while (HYDRA_UART_STATUS & HYDRA_UART_FULL) { }
  HYDRA_PUTCHAR = (uint8_t)ch;
}
static void put(const char *s) { while (*s) putc_wait(*s++); }

static void put_hex(uint64_t v) {
  static const char d[] = "0123456789abcdef";
  char b[19]; b[0] = '0'; b[1] = 'x'; b[18] = 0;
  for (int i = 17; i >= 2; i--) { b[i] = d[v & 15]; v >>= 4; }
  put(b);
}

static uint64_t fib(unsigned n) {
  uint64_t a = 0, b = 1;
  while (n--) { uint64_t t = a + b; a = b; b = t; }
  return a;
}

static uint32_t crc32(const char *p, unsigned len) {
  uint32_t c = 0xFFFFFFFFu;
  while (len--) {
    c ^= (uint8_t)*p++;
    for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1u)));
  }
  return ~c;
}

static volatile uint64_t mdu_in[2] = { 0x0123456789ABCDEFull, 0x00000000FEDCBA98ull };
static uint64_t scratch[4];                       /* .bss: crt0 must clear it */

int main(void) {
  put(greeting);
  uint64_t f = fib(60);                           /* 1548008755920 */
  uint32_t c = crc32(greeting, sizeof greeting - 1);
  uint64_t q = mdu_in[0] / mdu_in[1], r = mdu_in[0] % mdu_in[1];
  uint64_t back = q * mdu_in[1] + r;              /* must give mdu_in[0] back */
  put("fib(60) = "); put_hex(f);  put("\n");
  put("crc32   = "); put_hex(c);  put("\n");
  put("div ok  = "); put_hex(back == mdu_in[0]); put("\n");
  HYDRA_LEDS = 0x2A5C;                            /* the lab's blinky, once: a pattern on the LED pins */
  scratch[0] = f; scratch[1] = c;
  uint64_t bss_clear = scratch[2] | scratch[3];
  return (int)((f ^ c ^ (back == mdu_in[0] ? 0x5A5A : 0) ^ bss_clear) & 0x3FFFFFFF);
}
