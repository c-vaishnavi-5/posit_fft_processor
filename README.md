# Posit FFT Processor — RTL Implementation on FPGA

## Overview
8-point Radix-2 Decimation-in-Time (DIT) FFT core implemented in Verilog HDL 
using 32-bit Posit arithmetic (posit<32,3>) on Intel Cyclone V FPGA 
(DE10-Standard board). Achieves 100% dominant frequency bin detection accuracy 
across 15 real-world audio test signals.

## Tools & Technologies
- **HDL:** Verilog HDL
- **FPGA Tool:** Quartus Prime (Cyclone V — 5CSXFC6D6F31C6)
- **Simulation:** ModelSim
- **Interface:** UART (115200 bps, 8N1)
- **Post-processing:** Python (NumPy, SciPy)

## Key Features
- FSM-based time-multiplexed architecture reusing single butterfly unit 12×
- Pipelined Posit-32 multiplier (4-stage) and adder/subtractor (5-stage)
- UART PC-to-FPGA audio transfer pipeline

## Results
| Metric | Value |
|---|---|
| Clock Frequency | 25 MHz |
| Setup Slack | +17.058 ns |
| ALM Utilization | 6,930 / 41,910 (17%) |
| DSP Blocks | 4 |
| RMSE vs NumPy float64 | < 7.57 × 10⁻⁹ |
| SNR | 150.9 dB |
| Frequency Detection Accuracy | 100% (15/15 signals) |

## Repository Structure
├── rtl/          # Verilog HDL source files
├── testbench/    # Simulation testbenches
├── python/       # Audio preprocessing and analysis scripts
└── reports/      # Synthesis and timing reports
## Academic Context
B.Tech Final Year Project — VIT Chennai, April 2026  
Supervised by Dr. Augusta Sophy Beulet P
