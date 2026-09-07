// ============================================================================
// Project     : FIFO Portfolio – Part 2: Asynchronous FIFO (CDC)
// File        : async_fifo_tb.sv
// Date        : 2026-09-04
// Description : Self-checking testbench for parameterizable Asynchronous FIFO
//
// CDC Testing Strategy:
//   - We use independent clock generators with incommensurate frequencies
//     (100 MHz vs 37 MHz) to ensure edges slide past each other, testing
//     metastability conditions and synchronizer performance.
//   - A SystemVerilog queue [$] acts as the reference model to verify data
//     integrity and ordering across the clock domain crossing.
// ============================================================================

`timescale 1ns / 1ps

module async_fifo_tb;

    // ============================================================
    // Parameters & Signals
    // ============================================================
    parameter DATA_WIDTH = 8;
    parameter ADDR_WIDTH = 4;
    parameter FIFO_DEPTH = 1 << ADDR_WIDTH;

    // Write Domain
    logic                  wr_clk;
    logic                  wr_rst_n;
    logic                  wr_en;
    logic [DATA_WIDTH-1:0] wr_data;
    logic                  wr_full;

    // Read Domain
    logic                  rd_clk;
    logic                  rd_rst_n;
    logic                  rd_en;
    logic [DATA_WIDTH-1:0] rd_data;
    logic                  rd_empty;

    // Reference model variables
    logic [DATA_WIDTH-1:0] ref_queue[$];
    logic [DATA_WIDTH-1:0] expected_data;

    // Tracking variables
    int errors = 0;
    int writes_done = 0;
    int reads_done = 0;

    // ============================================================
    // Clock Generation
    // ============================================================
    // WHY THESE FREQUENCIES?
    // We want unaligned clock edges to thoroughly test the CDC logic.
    // 100 MHz (10ns) and ~37.03 MHz (27ns) are effectively incommensurate.

    // Write Clock: 100 MHz (10ns period) -> Fast writer
    initial begin
        wr_clk = 0;
        forever #5 wr_clk = ~wr_clk;
    end

    // Read Clock: 37 MHz (27ns period) -> Slow reader
    initial begin
        rd_clk = 0;
        forever #13.5 rd_clk = ~rd_clk;
    end


    // ============================================================
    // DUT Instantiation
    // ============================================================
    async_fifo #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) dut (
        .wr_clk     (wr_clk),
        .wr_rst_n   (wr_rst_n),
        .wr_en      (wr_en),
        .wr_data    (wr_data),
        .wr_full    (wr_full),

        .rd_clk     (rd_clk),
        .rd_rst_n   (rd_rst_n),
        .rd_en      (rd_en),
        .rd_data    (rd_data),
        .rd_empty   (rd_empty)
    );


    // ============================================================
    // Tasks
    // ============================================================

    // Reset Task - Safely reset both domains
    task reset_fifo();
        $display("[TIME: %0t] Resetting FIFO...", $time);
        wr_rst_n = 0;
        rd_rst_n = 0;
        wr_en    = 0;
        rd_en    = 0;
        wr_data  = 0;

        // Hold reset for several slow clock cycles
        #(27 * 3);

        // De-assert reset (asynchronous domains so we split them, but staggered slightly)
        @(negedge wr_clk); wr_rst_n = 1;
        @(negedge rd_clk); rd_rst_n = 1;

        // Wait for synchronizers to flush out any X's
        #(27 * 3);
        $display("[TIME: %0t] Reset complete.", $time);

        // Clear reference queue
        ref_queue.delete();
        errors = 0;
        writes_done = 0;
        reads_done  = 0;
    endtask

    // Write Task - Asserts write if not full
    task write_data(input logic [DATA_WIDTH-1:0] data);
        @(negedge wr_clk);
        if (wr_full) begin
            $display("[TIME: %0t] WARNING: Attempted to write %h while FULL. Checking protection.", $time, data);
            wr_en = 1;      // Drive en to test protection
            wr_data = data;
            @(negedge wr_clk);
            wr_en = 0;
        end else begin
            wr_en = 1;
            wr_data = data;
            ref_queue.push_back(data);  // Update reference model
            writes_done++;
            @(negedge wr_clk);
            wr_en = 0;
        end
    endtask

    // Read Task - Pops data if not empty and verifies
    task read_and_check();
        @(negedge rd_clk);
        if (rd_empty) begin
            $display("[TIME: %0t] WARNING: Attempted to read while EMPTY. Checking protection.", $time);
            rd_en = 1;     // Drive en to test protection
            @(negedge rd_clk);
            rd_en = 0;
        end else begin
            rd_en = 1;
            @(negedge rd_clk); // Wait for combinational read data to settle on falling edge

            if (ref_queue.size() == 0) begin
                $display("[FAIL] [TIME: %0t] Read valid but reference queue is empty!", $time);
                errors++;
            end else begin
                expected_data = ref_queue.pop_front();
                if (rd_data !== expected_data) begin
                    $display("[FAIL] [TIME: %0t] Data mismatch! Expected: %h, Got: %h", $time, expected_data, rd_data);
                    errors++;
                end else begin
                    reads_done++;
                    // $display("[PASS] [TIME: %0t] Let Rd_data = %h", $time, rd_data);
                end
            end

            rd_en = 0;
        end
    endtask


    // ============================================================
    // Test Sequence
    // ============================================================
    initial begin
        $display("\n============================================================");
        $display("   ASYNC FIFO TESTBENCH STARTING");
        $display("   Fast Writer (100MHz), Slow Reader (37MHz)");
        $display("============================================================\n");

        // --- Step 1: Initial Reset ---
        reset_fifo();

        // --- Step 2: Basic Read/Write ---
        $display("\n--- Test 2: Basic Pipeline Read/Write ---");
        write_data(8'hAA);
        write_data(8'hBB);

        // Wait for data to cross CDC into read domain (takes ~3 rd_clk cycles)
        #(27 * 4);

        read_and_check();
        read_and_check();


        // --- Step 3: Fast Write Burst (Testing Full Flag) ---
        $display("\n--- Test 3: Fast Write Burst (Overflow check) ---");
        // Our FIFO is depth 16. Let's write 20 items quickly.
        // The read clock is slow, so it won't drain fast enough. Full should trigger.
        for (int i = 0; i < 20; i++) begin
            write_data(8'h10 + i);
        end

        // We attempted 20 writes. 16 should succeed, 4 should drop.
        // Wait for system to settle
        #(27 * 4);

        // Drain it completely
        $display("Draining FIFO...");
        while (ref_queue.size() > 0 || !rd_empty) begin
            read_and_check();
            if (rd_empty && ref_queue.size() > 0) begin
                // Give it CDC time if empty is briefly true but we expect data
                #(27 * 2);
            end
        end


        // --- Step 4: Write during Empty / CDC Latency Test ---
        $display("\n--- Test 4: Write checking CDC latency to Empty flag ---");
        // Write 1 item. Read domain should NOT see it instantly due to 2FF sync.
        write_data(8'hFF);

        @(posedge rd_clk);
        if (rd_empty) begin
            $display("[TIME: %0t] Empty flag correctly remains asserted immediately after write (CDC latency).", $time);
        end else begin
            $display("[FAIL] Empty flag de-asserted too quickly. CDC might be bypassed!");
            errors++;
        end

        // Wait for CDC propagation
        #(27 * 4);
        read_and_check();


        // --- Step 5: Simultaneous Continuous Traffic ---
        $display("\n--- Test 5: Continuous Mixed Traffic ---");
        // Run concurrent write and read loops.
        // Because clocks are separate, we use fork-join to run them in parallel.
        fork
            // Write Thread
            begin
                for (int i = 0; i < 50; i++) begin
                    // Write occasionally when not full
                    @(negedge wr_clk);
                    if (!wr_full && ($urandom_range(0, 100) > 20)) begin
                        write_data($urandom_range(0, 255));
                    end
                end
            end

            // Read Thread
            begin
                for (int i = 0; i < 150; i++) begin
                    // Read occasionally when not empty
                    @(negedge rd_clk);
                    if (!rd_empty && ($urandom_range(0, 100) > 30)) begin
                        read_and_check();
                    end
                end
            end
        join

        // Wait to settle, then drain whatever is left
        #(27 * 5);
        while (ref_queue.size() > 0) begin
            read_and_check();
        end


        // ============================================================
        // Test Summary
        // ============================================================
        $display("\n============================================================");
        $display("   TEST SUMMARY");
        $display("============================================================");
        $display("   Writes completed : %0d", writes_done);
        $display("   Reads completed  : %0d", reads_done);

        if (errors == 0 && writes_done == reads_done && writes_done > 0) begin
            $display("\n   RESULT:  PASSED  [All %0d items matched exactly]", writes_done);
        end else begin
            $display("\n   RESULT:  FAILED  [%0d errors found]", errors);
            if (writes_done != reads_done)
                $display("   WARNING: Mismatch in total read vs total written.");
        end
        $display("============================================================\n");

        $finish;
    end

endmodule
