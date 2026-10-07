# Vivado, non-project mode: the whole build in one script, no GUI.
#   cd ~/src/hydra-skywater130 && vivado -mode batch -source fpga/build/basys3-selftest/build.tcl
# Part: XC7A35T-1CPG236C, the Basys 3's FPGA.
set out fpga/build/basys3-selftest
read_verilog -sv { fpga/rtl/hydra_fpga_uart.sv fpga/rtl/hydra_fpga_selftest.sv fpga/rtl/hydra_basys3_selftest.sv }
read_xdc $out/hydra_basys3_selftest.xdc
synth_design -top hydra_basys3_selftest -part xc7a35tcpg236-1
opt_design
place_design
route_design
report_utilization     -file $out/utilization.rpt
report_timing_summary  -file $out/timing.rpt
# Refuse to write a bitstream that misses timing: a board that works "most of
# the time" is the hardest kind of fault to find.
if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]] < 0} {
  puts "TIMING FAILED -- see $out/timing.rpt"; exit 1
}
write_bitstream -force $out/hydra_basys3_selftest.bit
puts "BITSTREAM $out/hydra_basys3_selftest.bit"
