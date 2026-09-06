// ============================================================
// Project  : Synchronous FIFO
// Date     : September 2026
// Description:
//   Parameterizable synchronous FIFO (First-In, First-Out) buffer.
//   Single clock domain design using binary read/write pointers
//   with an extra MSB bit for unambiguous full/empty detection.
//
//   Key concept (interview talking point):
//   Both pointers are (ADDR_WIDTH+1) bits wide. The lower
//   ADDR_WIDTH bits index into the RAM. The extra MSB acts as
//   a "wrap-around" flag:
//     - EMPTY: wr_ptr == rd_ptr          (same address, same wrap)
//     - FULL:  lower bits match BUT MSBs differ (same address,
//              but writer has wrapped one more time than reader)
//   This avoids needing a separate counter for full/empty, which
//   is the standard trick used in production FIFO designs.
// ============================================================

module sync_fifo #(
    parameter int DATA_WIDTH = 8,           // Width of each data word
    parameter int FIFO_DEPTH = 16           // Number of entries (must be power of 2)
)(
    input  logic                    clk,
    input  logic                    rst_n,    // Active-low asynchronous reset

    // Write interface
    input  logic                    wr_en,    // Write enable (request)
    input  logic [DATA_WIDTH-1:0]   wr_data,  // Data to write

    // Read interface
    input  logic                    rd_en,    // Read enable (request)
    output logic [DATA_WIDTH-1:0]   rd_data,  // Data read out

    // Status flags
    output logic                    full,
    output logic                    empty,
    output logic                    almost_full,   // fill_count >= DEPTH - 1
    output logic                    almost_empty,  // fill_count <= 1

    // Debug / monitoring
    output logic [$clog2(FIFO_DEPTH):0] fill_count // Number of valid entries
);

    // ============================================================
    // Local Parameters
    // ============================================================
    localparam int ADDR_WIDTH = $clog2(FIFO_DEPTH);

    // ============================================================
    // Internal Signals
    // ============================================================

    // Pointers are one bit wider than the address: the extra MSB
    // is the wrap-around indicator used for full/empty detection.
    logic [ADDR_WIDTH:0] wr_ptr;
    logic [ADDR_WIDTH:0] rd_ptr;

    // RAM addresses are the lower ADDR_WIDTH bits of each pointer.
    logic [ADDR_WIDTH-1:0] wr_addr;
    logic [ADDR_WIDTH-1:0] rd_addr;

    // Internal write/read qualifiers — actual operations happen
    // only when the request is valid AND the FIFO allows it.
    logic wr_valid;
    logic rd_valid;

    // Storage: simple register-based dual-port RAM.
    // Depth x Width array inferred as flip-flops (fine for small FIFOs;
    // for large depths a vendor RAM macro would be instantiated instead).
    logic [DATA_WIDTH-1:0] mem [0:FIFO_DEPTH-1];

    // ============================================================
    // Address Extraction
    // ============================================================
    assign wr_addr = wr_ptr[ADDR_WIDTH-1:0];
    assign rd_addr = rd_ptr[ADDR_WIDTH-1:0];

    // ============================================================
    // Full / Empty Detection (the extra-bit trick)
    // ============================================================
    // EMPTY: both pointers are identical — same wrap count, same address.
    // FULL:  lower address bits match, but MSBs differ — the writer
    //        has wrapped around exactly once more than the reader,
    //        meaning every slot in the RAM is occupied.
    assign empty = (wr_ptr == rd_ptr);
    assign full  = (wr_ptr[ADDR_WIDTH] != rd_ptr[ADDR_WIDTH]) &&
                   (wr_addr == rd_addr);

    // ============================================================
    // Fill Count
    // ============================================================
    // Subtraction of the two (ADDR_WIDTH+1)-bit pointers gives the
    // correct occupancy even across wrap-around because of unsigned
    // modular arithmetic on the extended-width pointers.
    assign fill_count = wr_ptr - rd_ptr;

    // ============================================================
    // Almost-Full / Almost-Empty
    // ============================================================
    assign almost_full  = (fill_count >= FIFO_DEPTH - 1);
    assign almost_empty = (fill_count <= 1);

    // ============================================================
    // Write / Read Qualification
    // ============================================================
    // Guard against illegal operations: never write a full FIFO,
    // never read an empty one.
    assign wr_valid = wr_en && !full;
    assign rd_valid = rd_en && !empty;

    // ============================================================
    // Write Pointer & Memory Write
    // ============================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
        end else if (wr_valid) begin
            mem[wr_addr] <= wr_data;        // Write data into RAM
            wr_ptr       <= wr_ptr + 1'b1;  // Advance pointer
        end
    end

    // ============================================================
    // Read Pointer & Memory Read
    // ============================================================
    // Read data is registered (one-cycle latency after rd_en).
    // This gives cleaner timing; for zero-latency "look-ahead"
    // reads, rd_data could instead be a combinational assign.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr  <= '0;
            rd_data <= '0;
        end else if (rd_valid) begin
            rd_data <= mem[rd_addr];         // Capture data from RAM
            rd_ptr  <= rd_ptr + 1'b1;        // Advance pointer
        end
    end

endmodule
