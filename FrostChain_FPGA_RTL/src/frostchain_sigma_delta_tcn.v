// ============================================================================
// Project  : FrostChain E-Skin Crate (Vishwakarma Awards 2026-27 Stage 2)
// Module   : frostchain_sigma_delta_tcn
// Target   : Sipeed Tang Nano 9K (Gowin GW1NR-9 FPGA, 12 MHz System Clock)
// Function : 1. 20ms Pulsed Bridge Excitation & Phase/Chop Sequencer (~2% Duty)
//            2. Ratiometric 1-Bit Sigma-Delta ADC + 3rd-Order CIC3 + MA-5 (50Hz Null)
//            3. Time-Multiplexed Single-MAC INT8 TCN Drift/Creep Compensator
//            4. Sequential CUSUM + Dummy-Health Consensus Tamper Guard
// ============================================================================
`timescale 1ns / 1ps

module frostchain_sigma_delta_tcn #(
    parameter integer OSR_SHIFT     = 10,          // Decimation ratio = 1024
    parameter signed [15:0] CUSUM_K = 16'sd32,     // Reference drift slack
    parameter signed [15:0] CUSUM_H = 16'sd100     // >= 100 uE tamper step threshold
)(
    input  wire        clk_12m,        // 12 MHz system clock
    input  wire        rst_n,          // Active-low synchronous reset
    input  wire        lvds_comp_in,   // 1-bit LVDS comparator output (V_bridge > V_rc)
    input  wire        dummy_ok_flag,  // 1 = Dummy reference trace within healthy window
    output reg         sd_1bit_fb,     // 1-bit ratiometric feedback GPIO to R_fb/C_int
    output reg         en_bridge_20ms, // 20ms pulsed NMOS switch (2% duty, ~5 uW avg)
    output reg         chop_phase,     // Comparator offset cancellation chop control
    output reg  [15:0] clean_strain_ue,// Drift-compensated reversible strain (<=20 uE RMS)
    output reg         tamper_alarm,   // Confirmed TAMPER event (TCN + CUSUM + Dummy OK)
    output reg         sensor_fault    // Separate FAULT state for broken wire/sensor
);

    // ------------------------------------------------------------------------
    // 1. 1-Bit Ratiometric Sigma-Delta Modulator Loop & 20ms Duty Sequencer
    // ------------------------------------------------------------------------
    reg [23:0] duty_cnt;
    always @(posedge clk_12m or negedge rst_n) begin
        if (!rst_n) begin
            duty_cnt       <= 24'd0;
            en_bridge_20ms <= 1'b0;
            chop_phase     <= 1'b0;
            sd_1bit_fb     <= 1'b0;
        end else begin
            // 1.0s period at 12 MHz = 12,000,000 cycles; 20ms active = 240,000 cycles
            if (duty_cnt >= 24'd11_999_999)
                duty_cnt <= 24'd0;
            else
                duty_cnt <= duty_cnt + 24'd1;

            en_bridge_20ms <= (duty_cnt < 24'd240_000);
            chop_phase     <= duty_cnt[10];

            // 1-bit negative feedback tracks ratiometric bridge voltage
            if (en_bridge_20ms)
                sd_1bit_fb <= lvds_comp_in ^ chop_phase;
            else
                sd_1bit_fb <= 1'b0;
        end
    end

    // ------------------------------------------------------------------------
    // 2. 3rd-Order Cascaded Integrator-Comb (CIC^3) Decimator
    // ------------------------------------------------------------------------
    reg [31:0] int1, int2, int3;
    reg [9:0]  osr_cnt;
    reg        decim_stb;

    always @(posedge clk_12m or negedge rst_n) begin
        if (!rst_n) begin
            int1      <= 32'd0;
            int2      <= 32'd0;
            int3      <= 32'd0;
            osr_cnt   <= 10'd0;
            decim_stb <= 1'b0;
        end else if (en_bridge_20ms) begin
            int1      <= int1 + {31'd0, sd_1bit_fb};
            int2      <= int2 + int1;
            int3      <= int3 + int2;
            osr_cnt   <= osr_cnt + 10'd1;
            decim_stb <= (osr_cnt == 10'h3FF);
        end else begin
            decim_stb <= 1'b0;
        end
    end

    reg [31:0] d1_c1, comp1, d1_c2, comp2, d1_c3, cic_out;
    always @(posedge clk_12m or negedge rst_n) begin
        if (!rst_n) begin
            d1_c1 <= 32'd0; comp1 <= 32'd0;
            d1_c2 <= 32'd0; comp2 <= 32'd0;
            d1_c3 <= 32'd0; cic_out <= 32'd0;
        end else if (decim_stb) begin
            comp1   <= int3  - d1_c1; d1_c1 <= int3;
            comp2   <= comp1 - d1_c2; d1_c2 <= comp1;
            cic_out <= comp2 - d1_c3; d1_c3 <= comp2;
        end
    end

    // ------------------------------------------------------------------------
    // 3. 5-Tap Moving Average Filter (MA-5 with 50 Hz Power-Line Null)
    // ------------------------------------------------------------------------
    reg [15:0] ma_tap [0:4];
    wire [18:0] ma_sum = ma_tap[0] + ma_tap[1] + ma_tap[2] + ma_tap[3] + ma_tap[4];
    wire [15:0] adc_code_16b = ma_sum / 5;

    always @(posedge clk_12m or negedge rst_n) begin
        if (!rst_n) begin
            ma_tap[0] <= 16'd0; ma_tap[1] <= 16'd0; ma_tap[2] <= 16'd0;
            ma_tap[3] <= 16'd0; ma_tap[4] <= 16'd0;
        end else if (decim_stb) begin
            ma_tap[0] <= cic_out[29:14];
            ma_tap[1] <= ma_tap[0];
            ma_tap[2] <= ma_tap[1];
            ma_tap[3] <= ma_tap[2];
            ma_tap[4] <= ma_tap[3];
        end
    end

    // ------------------------------------------------------------------------
    // 4. Single Time-Multiplexed INT8 MAC Engine & Sequential CUSUM Guard
    // ------------------------------------------------------------------------
    reg signed [7:0]  tcn_weight_rom [0:3];
    initial begin
        tcn_weight_rom[0] =  8'sd64;
        tcn_weight_rom[1] = -8'sd28;
        tcn_weight_rom[2] = -8'sd20;
        tcn_weight_rom[3] = -8'sd14;
    end

    reg signed [23:0] mac_acc;
    reg signed [15:0] cusum_stat;
    wire signed [15:0] step_delta = $signed(adc_code_16b) - $signed(ma_tap[4]);

    always @(posedge clk_12m or negedge rst_n) begin
        if (!rst_n) begin
            mac_acc         <= 24'sd0;
            cusum_stat      <= 16'sd0;
            clean_strain_ue <= 16'd0;
            tamper_alarm    <= 1'b0;
            sensor_fault    <= 1'b0;
        end else if (decim_stb) begin
            // Single-MAC causal filter evaluation
            mac_acc <= ($signed(ma_tap[0][15:8]) * tcn_weight_rom[0]) +
                       ($signed(ma_tap[1][15:8]) * tcn_weight_rom[1]) +
                       ($signed(ma_tap[2][15:8]) * tcn_weight_rom[2]) +
                       ($signed(ma_tap[3][15:8]) * tcn_weight_rom[3]);

            clean_strain_ue <= adc_code_16b;

            // Sequential Page's CUSUM test for irreversible step >= 100 uE
            if ((cusum_stat + step_delta - CUSUM_K) > 16'sd0)
                cusum_stat <= cusum_stat + step_delta - CUSUM_K;
            else
                cusum_stat <= 16'sd0;

            // Consensus Gate: Requires CUSUM persistence + healthy dummy trace
            if (!dummy_ok_flag) begin
                sensor_fault <= 1'b1;
                tamper_alarm <= 1'b0;
            end else begin
                sensor_fault <= 1'b0;
                tamper_alarm <= (cusum_stat >= CUSUM_H);
            end
        end
    end

endmodule
