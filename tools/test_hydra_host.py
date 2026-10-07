"""Encoding tests for hydra_host.py -- no hardware needed.

The values are cross-checked against the constants the simulation used:
tb_fpga_harness.sv replays exactly these bytes, and test_regs.py builds the
same descriptors, so an encoding drift here shows up as a simulation failure
rather than a silent wrong answer on the bench.
"""
import hydra_host as h


def test_descriptor_matches_the_simulation_constants():
    assert h.descriptor(m=4, n=4, k=4, nbytes=48) == 0x30a00080008000800006000000000000
    assert h.descriptor(m=8, n=8, k=8, nbytes=192) == 0x30a00100010001000018000000000000


def test_default_param_rows_match_mom_param_rom():
    # {p_peak[4], t_setup[12], bw[4], eps[8], dtype[6], opc[9]} = 43 bits
    assert h.DEF["TPU"] == int("0111" "000001000000" "0101" "00000010" "000011" "000011000", 2)
    assert all(row < (1 << 43) for row in h.DEF.values())


def test_frame_bytes_read_and_write():
    assert h.frame_bytes(h.A_ID, True) == bytes([0x80, 0, 0, 0, 0])
    assert h.frame_bytes(h.A_ACTION, False, 1) == bytes([0x03, 0x01])
    wd = h.frame_bytes(h.A_WD, False, h.descriptor(m=4, n=4, k=4, nbytes=48))
    assert len(wd) == 17 and wd[0] == 0x01 and wd[1:3] == bytes([0x30, 0xa0])


def test_uart_frame_limit():
    assert h.uart_frame(b"\x01\x02") == bytes([0xA5, 2, 1, 2])
    try:
        h.uart_frame(bytes(33))
    except ValueError:
        return
    raise AssertionError("a 33-byte frame should be refused: the harness buffer is 32")


# ---------------------------------------------------------------------------
# Scratchpad helpers. These encode a wire format and a bank layout, so they
# are exactly the kind of thing that drifts from the hardware silently.
# ---------------------------------------------------------------------------
def test_pack_lanes_puts_lane_zero_in_the_low_byte():
    assert h.pack_lanes([1, 2, 3, 4]) == 0x04030201


def test_pack_lanes_keeps_negative_operands_two_s_complement():
    assert h.pack_lanes([-1, -128, 127, 0]) == 0x007F80FF


def test_gemm_descriptor_carries_all_three_bank_addresses():
    d = h.gemm_descriptor(4, 4, 8, base_a=5, base_b=9, base_c=64)
    v = int.from_bytes(d, "big") if isinstance(d, (bytes, bytearray)) else d
    assert (v >> 3) & 0x3FF == 5
    assert (v >> 13) & 0x3FF == 9
    assert (v >> 23) & 0x3FF == 64
    assert (v >> 124) & 0xF == 3          # still a GEMM
    assert (v >> 84) & 0xFFFF == 8        # still dim_k


def test_gemm_descriptor_leaves_the_vector_opcode_field_alone():
    # The vector unit owns bits [2:0]; a base address must not reach them.
    d = h.gemm_descriptor(4, 4, 4, base_a=0x3FF, base_b=0x3FF,
                                   base_c=0x3FF)
    v = int.from_bytes(d, "big") if isinstance(d, (bytes, bytearray)) else d
    assert v & 0x7 == 0
