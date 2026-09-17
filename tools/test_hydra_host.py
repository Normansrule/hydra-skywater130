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
