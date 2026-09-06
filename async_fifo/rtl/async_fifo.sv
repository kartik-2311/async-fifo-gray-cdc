`timescale 1ns / 1ps


// ==========================================================================
// Module 1: Dual-Port RAM
// ==========================================================================
module async_fifo_mem #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 4              // Depth = 2**ADDR_WIDTH = 16
)(
    input  logic                  wr_clk,
    input  logic                  wr_en,    // Gated externally: only HIGH when not full
    input  logic [ADDR_WIDTH-1:0] wr_addr,
    input  logic [DATA_WIDTH-1:0] wr_data,
    input  logic [ADDR_WIDTH-1:0] rd_addr,
    output logic [DATA_WIDTH-1:0] rd_data
);

    // ---- Storage array ----
    logic [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];

    // Synchronous write
    always_ff @(posedge wr_clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end

    // Combinational (async) read
    assign rd_data = mem[rd_addr];

endmodule


// ==========================================================================
// Module 2: 2-Flop Synchronizer
// ==========================================================================
module sync_2ff #(
    parameter WIDTH = 1
)(
    input  logic             clk,       // Destination clock
    input  logic             rst_n,     // Destination reset (active-low)
    input  logic [WIDTH-1:0] d_in,      // Input from source domain
    output logic [WIDTH-1:0] q_out      // Synchronized output in dest domain
);

    // Two-stage pipeline
    logic [WIDTH-1:0] meta_ff;  // Stage 1 — may go metastable
    logic [WIDTH-1:0] sync_ff;  // Stage 2 — resolved, safe to use

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            meta_ff <= '0;
            sync_ff <= '0;
        end else begin
            meta_ff <= d_in;
            sync_ff <= meta_ff;
        end
    end

    assign q_out = sync_ff;

endmodule


// ==========================================================================
// Module 3: Write Pointer & Full Flag Generation
// ==========================================================================
module async_fifo_wr_ptr #(
    parameter ADDR_WIDTH = 4
)(
    input  logic                    wr_clk,
    input  logic                    wr_rst_n,
    input  logic                    wr_en,
    input  logic [ADDR_WIDTH:0]     rd_gray_sync,
    output logic [ADDR_WIDTH-1:0]   wr_addr,
    output logic [ADDR_WIDTH:0]     wr_gray_ptr,
    output logic                    wr_full
);

    // Binary pointer: ADDR_WIDTH+1 bits (extra MSB for wrap detection)
    logic [ADDR_WIDTH:0] wr_bin;
    logic [ADDR_WIDTH:0] wr_bin_next;
    logic [ADDR_WIDTH:0] wr_gray_next;
    logic                wr_full_next;

    // Increment logic
    assign wr_bin_next  = wr_bin + (wr_en & ~wr_full);
    assign wr_gray_next = wr_bin_next ^ (wr_bin_next >> 1);
    assign wr_full_next = (wr_gray_next[ADDR_WIDTH]     != rd_gray_sync[ADDR_WIDTH])   &&
                          (wr_gray_next[ADDR_WIDTH-1]   != rd_gray_sync[ADDR_WIDTH-1]) &&
                          (wr_gray_next[ADDR_WIDTH-2:0] == rd_gray_sync[ADDR_WIDTH-2:0]);

    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bin <= '0;
            wr_gray_ptr <= '0;
            wr_full <= 1'b0;
        end else begin
            wr_bin <= wr_bin_next;
            wr_gray_ptr <= wr_gray_next;
            wr_full <= wr_full_next;
        end
    end

    assign wr_addr = wr_bin[ADDR_WIDTH-1:0];

endmodule


// ==========================================================================
// Module 4: Read Pointer & Empty Flag Generation
// ==========================================================================
module async_fifo_rd_ptr #(
    parameter ADDR_WIDTH = 4
)(
    input  logic                    rd_clk,
    input  logic                    rd_rst_n,
    input  logic                    rd_en,
    input  logic [ADDR_WIDTH:0]     wr_gray_sync,
    output logic [ADDR_WIDTH-1:0]   rd_addr,
    output logic [ADDR_WIDTH:0]     rd_gray_ptr,
    output logic                    rd_empty
);

    // Binary pointer: ADDR_WIDTH+1 bits
    logic [ADDR_WIDTH:0] rd_bin;
    logic [ADDR_WIDTH:0] rd_bin_next;
    logic [ADDR_WIDTH:0] rd_gray_next;
    logic                rd_empty_next;

    assign rd_bin_next = rd_bin + (rd_en & ~rd_empty);
    assign rd_gray_next = rd_bin_next ^ (rd_bin_next >> 1);
    assign rd_empty_next = (rd_gray_next == wr_gray_sync);

    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_bin <= '0;
            rd_gray_ptr <= '0;
            rd_empty <= 1'b1;
        end else begin
            rd_bin <= rd_bin_next;
            rd_gray_ptr <= rd_gray_next;
            rd_empty <= rd_empty_next;
        end
    end

    assign rd_addr = rd_bin[ADDR_WIDTH-1:0];

endmodule


// ==========================================================================
// Top-Level Module: Asynchronous FIFO
// ==========================================================================
module async_fifo #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 4
)(
    // Write domain
    input  logic                  wr_clk,
    input  logic                  wr_rst_n,
    input  logic                  wr_en,
    input  logic [DATA_WIDTH-1:0] wr_data,
    output logic                  wr_full,
    // Read domain
    input  logic                  rd_clk,
    input  logic                  rd_rst_n,
    input  logic                  rd_en,
    output logic [DATA_WIDTH-1:0] rd_data,
    output logic                  rd_empty
);

    logic [ADDR_WIDTH-1:0] wr_addr;
    logic [ADDR_WIDTH-1:0] rd_addr;
    logic [ADDR_WIDTH:0]   wr_gray_ptr;
    logic [ADDR_WIDTH:0]   rd_gray_ptr;
    logic [ADDR_WIDTH:0]   wr_gray_sync;
    logic [ADDR_WIDTH:0]   rd_gray_sync;

    logic wr_en_gated;

    assign wr_en_gated = wr_en & ~wr_full;

    // RAM
    async_fifo_mem #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_mem (
        .wr_clk(wr_clk),
        .wr_en(wr_en_gated),
        .wr_addr(wr_addr),
        .wr_data(wr_data),
        .rd_addr(rd_addr),
        .rd_data(rd_data)
    );

    // Write pointer & full logic
    async_fifo_wr_ptr #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_wr_ptr (
        .wr_clk(wr_clk),
        .wr_rst_n(wr_rst_n),
        .wr_en(wr_en),
        .rd_gray_sync(rd_gray_sync),
        .wr_addr(wr_addr),
        .wr_gray_ptr(wr_gray_ptr),
        .wr_full(wr_full)
    );

    // Read pointer & empty logic
    async_fifo_rd_ptr #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_rd_ptr (
        .rd_clk(rd_clk),
        .rd_rst_n(rd_rst_n),
        .rd_en(rd_en),
        .wr_gray_sync(wr_gray_sync),
        .rd_addr(rd_addr),
        .rd_gray_ptr(rd_gray_ptr),
        .rd_empty(rd_empty)
    );

    // Synchronizers
    sync_2ff #(
        .WIDTH(ADDR_WIDTH + 1)
    ) u_sync_wr2rd (
        .clk(rd_clk),
        .rst_n(rd_rst_n),
        .d_in(wr_gray_ptr),
        .q_out(wr_gray_sync)
    );

    sync_2ff #(
        .WIDTH(ADDR_WIDTH + 1)
    ) u_sync_rd2wr (
        .clk(wr_clk),
        .rst_n(wr_rst_n),
        .d_in(rd_gray_ptr),
        .q_out(rd_gray_sync)
    );

endmodule
