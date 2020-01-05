// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Michael Schaffner <schaffner@iis.ee.ethz.ch>, ETH Zurich
// Date: 13.09.2018
// Description: Instruction cache that is compatible with openpiton.

import ariane_pkg::*;
import wt_cache_pkg::*;

module wt_dcache #(
  // ID to be used for read and AMO transactions.
  // note that the write buffer uses all IDs up to DCACHE_MAX_TX-1 for write transactions
  parameter logic [CACHE_ID_WIDTH-1:0]   RdAmoTxId          = 1,
  // contains cacheable regions
  parameter ariane_pkg::ariane_cfg_t     ArianeCfg          = ariane_pkg::ArianeDefaultConfig
) (
  input  logic                           clk_i,       // Clock
  input  logic                           rst_ni,      // Asynchronous reset active low

  // Cache management
  input  logic                           enable_i,    // from CSR
  input  logic                           flush_i,     // high until acknowledged
  output logic                           flush_ack_o, // send a single cycle acknowledge signal when the cache is flushed
  output logic                           miss_o,      // we missed on a ld/st
  output logic                           wbuffer_empty_o,

  // AMO interface
  input  amo_req_t                       amo_req_i,
  output amo_resp_t                      amo_resp_o,

  // Request ports
  input  dcache_req_i_t [2:0]            req_ports_i,
  output dcache_req_o_t [2:0]            req_ports_o,

  input  logic                           mem_rtrn_vld_i,
  input  dcache_rtrn_t                   mem_rtrn_i,
  output logic                           mem_data_req_o,
  input  logic                           mem_data_ack_i,
  output dcache_req_t                    mem_data_o
);

  // LD unit and PTW
  localparam NumPorts = 3;

  // miss unit <-> read controllers
  logic cache_en;

  // miss unit <-> memory
  logic [$clog2(DCACHE_SET_ASSOC)-1:0]  wr_sig_we;
  logic                           write_signature;
  logic [13:0]                    wr_cl_signature;
  logic                           wr_cl_vld;
  logic                           wr_cl_nc;
  logic                           wr_cl_line_upgraded;
  logic [DCACHE_SET_ASSOC-1:0]    wr_cl_we;
  logic [DCACHE_TAG_WIDTH-1:0]    wr_cl_tag;
  logic [DCACHE_CL_IDX_WIDTH-1:0] wr_cl_idx;
  logic [DCACHE_OFFSET_WIDTH-1:0] wr_cl_off;
  logic [DCACHE_LINE_WIDTH-1:0]   wr_cl_data;
  logic [DCACHE_LINE_WIDTH/8-1:0] wr_cl_data_be;
  logic [DCACHE_SET_ASSOC-1:0]    wr_vld_bits;
  logic [DCACHE_SET_ASSOC-1:0]    wr_req;
  logic                           wr_ack;
  logic [DCACHE_CL_IDX_WIDTH-1:0] wr_idx;
  logic [DCACHE_OFFSET_WIDTH-1:0] wr_off;
  logic [63:0]                    wr_data;
  logic [7:0]                     wr_data_be;
  //predictor interface
  logic				         pred_outcome;
  logic	[13:0]			  pred_hit_shct;
  logic [13:0]			  pred_miss_shct;
  //lru interface
  logic						    hit;
  logic [DCACHE_CL_IDX_WIDTH-1:0]	    	    hit_idx;
  logic	[$clog2(DCACHE_SET_ASSOC)-1:0]		  hit_way;
/*  logic						    lru_mshr;
  logic [DCACHE_CL_IDX_WIDTH-1:0]	    	    lru_mshr_idx;
  logic	[$clog2(DCACHE_SET_ASSOC)-1:0]		    lru_mshr_way;
  logic	[DCACHE_CL_IDX_WIDTH-1:0]	    	    lru_miss_idx;*/

  // miss unit <-> controllers/wbuffer
  logic [NumPorts-1:0]                          miss_req;
  logic [NumPorts-1:0]                          miss_ack;
  logic [NumPorts-1:0]                          miss_nc;
  logic [NumPorts-1:0]                          miss_we;
  logic [NumPorts-1:0][63:0]                    miss_wdata;
  logic [NumPorts-1:0][13:0]                    miss_signature;
  logic [NumPorts-1:0][63:0]                    miss_paddr;
  logic [NumPorts-1:0][DCACHE_SET_ASSOC-1:0]    miss_vld_bits;
  logic [NumPorts-1:0][DCACHE_SET_ASSOC-1:0]    miss_ever_hit;
  logic [NumPorts-1:0][$clog2(DCACHE_SET_ASSOC)-1:0] miss_rep_way;
  logic [NumPorts-1:0]                          miss_rep_way_vld;
  logic [NumPorts-1:0][2:0]                     miss_size;
  logic [NumPorts-1:0][CACHE_ID_WIDTH-1:0]      miss_id;
  logic [NumPorts-1:0]                          miss_replay;
  logic [NumPorts-1:0]                          miss_rtrn_vld;
  logic [CACHE_ID_WIDTH-1:0]                    miss_rtrn_id;

  // memory <-> read controllers/miss unit
  logic [NumPorts-1:0]                          rd_prio;
  logic [NumPorts-1:0]                          rd_tag_only;
  logic [NumPorts-1:0]                          rd_req;
  logic [NumPorts-1:0]                          rd_ack;
  logic [NumPorts-1:0][DCACHE_TAG_WIDTH-1:0]    rd_tag;
  logic [NumPorts-1:0][DCACHE_CL_IDX_WIDTH-1:0] rd_idx;
  logic [NumPorts-1:0][DCACHE_OFFSET_WIDTH-1:0] rd_off;
  logic [63:0]                                  rd_data;
  logic [DCACHE_SET_ASSOC-1:0]                  rd_vld_bits;
  logic [DCACHE_SET_ASSOC-1:0]                  rd_hit_oh;
  logic [DCACHE_SET_ASSOC-1:0]                  rd_ever_hit;
  logic [$clog2(DCACHE_SET_ASSOC)-1:0]          rd_rep_way;        // use this way in case of miss
  logic                                         rd_rep_way_vld;   // force the way to be the one used in replace

  // miss unit <-> wbuffer
  logic [DCACHE_MAX_TX-1:0][63:0]               tx_paddr;
  logic [DCACHE_MAX_TX-1:0]                     tx_vld;

  // wbuffer <-> memory
  wbuffer_t [DCACHE_WBUF_DEPTH-1:0]             wbuffer_data;


///////////////////////////////////////////////////////
// miss handling unit
///////////////////////////////////////////////////////

  wt_dcache_missunit #(
    .Axi64BitCompliant ( ArianeCfg.Axi64BitCompliant ),
    .AmoTxId           ( RdAmoTxId                   ),
    .NumPorts          ( NumPorts                    )
  ) i_wt_dcache_missunit (
    .clk_i              ( clk_i              ),
    .rst_ni             ( rst_ni             ),
    .enable_i           ( enable_i           ),
    .flush_i            ( flush_i            ),
    .flush_ack_o        ( flush_ack_o        ),
    .miss_o             ( miss_o             ),
    .wbuffer_empty_i    ( wbuffer_empty_o    ),
    .cache_en_o         ( cache_en           ),
    // amo interface
    .amo_req_i          ( amo_req_i          ),
    .amo_resp_o         ( amo_resp_o         ),
    // miss handling interface
    .miss_signature_i   ( miss_signature     ),
    .miss_req_i         ( miss_req           ),
    .miss_ack_o         ( miss_ack           ),
    .miss_nc_i          ( miss_nc            ),
    .miss_we_i          ( miss_we            ),
    .miss_wdata_i       ( miss_wdata         ),
    .miss_paddr_i       ( miss_paddr         ),
    .miss_vld_bits_i    ( miss_vld_bits      ),
    .miss_ever_hit_i    ( miss_ever_hit      ),
    .miss_rep_way_i     ( miss_rep_way       ),
    .miss_rep_way_vld_i ( miss_rep_way_vld   ),
    .miss_size_i        ( miss_size          ),
    .miss_id_i          ( miss_id            ),
    .miss_replay_o      ( miss_replay        ),
    .miss_rtrn_vld_o    ( miss_rtrn_vld      ),
    .miss_rtrn_id_o     ( miss_rtrn_id       ),
    // from writebuffer
    .tx_paddr_i         ( tx_paddr           ),
    .tx_vld_i           ( tx_vld             ),
    // cache memory interface
    .wr_cl_vld_o        ( wr_cl_vld          ),
    .wr_cl_nc_o         ( wr_cl_nc           ),
    .wr_cl_line_upgraded_o ( wr_cl_line_upgraded ),
    .wr_cl_we_o         ( wr_cl_we           ),
    .wr_cl_tag_o        ( wr_cl_tag          ),
    .wr_cl_idx_o        ( wr_cl_idx          ),
    .wr_cl_off_o        ( wr_cl_off          ),
    .wr_cl_data_o       ( wr_cl_data         ),
    .wr_cl_data_be_o    ( wr_cl_data_be      ),
    .wr_vld_bits_o      ( wr_vld_bits        ),
    .wr_sig_we_o        ( wr_sig_we          ),
    .write_signature_o  ( write_signature    ),
    .wr_cl_signature_o  ( wr_cl_signature    ),
   // memory interface
    .mem_rtrn_vld_i     ( mem_rtrn_vld_i     ),
    .mem_rtrn_i         ( mem_rtrn_i         ),
    .mem_data_req_o     ( mem_data_req_o     ),
    .mem_data_ack_i     ( mem_data_ack_i     ),
    .mem_data_o         ( mem_data_o         ),

    // input to predictor
    .pred_outcome_i    ( pred_outcome	    ),
    .pred_hit_shct_i   ( pred_hit_shct	    ),
    .pred_miss_shct_i  ( pred_miss_shct	    ),


    // input to lru
    .hit_i	       ( hit	    ),
    .hit_idx_i         ( hit_idx    ),
    .hit_way_i         ( hit_way    )
    /*.lru_mshr_i	       ( lru_mshr	    ),
    .lru_mshr_idx_i    ( lru_mshr_idx       ),
    .lru_mshr_way_i    ( lru_mshr_way	    ),
    .lru_miss_idx_i    ( lru_miss_idx	    )*/
  );

///////////////////////////////////////////////////////
// read controllers (LD unit and PTW/MMU)
///////////////////////////////////////////////////////

  // note: last read port is used by the write buffer
  for(genvar k=0; k<NumPorts-1; k++) begin : gen_rd_ports
    // set these to high prio ports
    assign rd_prio[k] = 1'b1;

    wt_dcache_ctrl #(
      .RdTxId        ( RdAmoTxId     ),
      .ArianeCfg     ( ArianeCfg     )
    ) i_wt_dcache_ctrl (
      .clk_i           ( clk_i             ),
      .rst_ni          ( rst_ni            ),
      .cache_en_i      ( cache_en          ),
      // reqs from core
      .req_port_i      ( req_ports_i   [k] ),
      .req_port_o      ( req_ports_o   [k] ),
      // miss interface
      .miss_signature_o( miss_signature[k] ),
      .miss_req_o      ( miss_req      [k] ),
      .miss_ack_i      ( miss_ack      [k] ),
      .miss_we_o       ( miss_we       [k] ),
      .miss_wdata_o    ( miss_wdata    [k] ),
      .miss_vld_bits_o ( miss_vld_bits [k] ),
      .miss_ever_hit_o ( miss_ever_hit [k] ),
      .miss_rep_way_o  ( miss_rep_way  [k] ),
      .miss_rep_way_vld_o ( miss_rep_way_vld [k] ),
      .miss_paddr_o    ( miss_paddr    [k] ),
      .miss_nc_o       ( miss_nc       [k] ),
      .miss_size_o     ( miss_size     [k] ),
      .miss_id_o       ( miss_id       [k] ),
      .miss_replay_i   ( miss_replay   [k] ),
      .miss_rtrn_vld_i ( miss_rtrn_vld [k] ),
      // used to detect readout mux collisions
      .wr_cl_vld_i     ( wr_cl_vld         ),
      // cache mem interface
      .rd_tag_o        ( rd_tag        [k] ),
      .rd_idx_o        ( rd_idx        [k] ),
      .rd_off_o        ( rd_off        [k] ),
      .rd_req_o        ( rd_req        [k] ),
      .rd_tag_only_o   ( rd_tag_only   [k] ),
      .rd_ack_i        ( rd_ack        [k] ),
      .rd_data_i       ( rd_data           ),
      .rd_vld_bits_i   ( rd_vld_bits       ),
      .rd_ever_hit_i   ( rd_ever_hit       ),
      .rd_rep_way_i    ( rd_rep_way        ),
      .rd_rep_way_vld_i ( rd_rep_way_vld   ),
      .rd_hit_oh_i     ( rd_hit_oh         )
    );
  end
///////////////////////////////////////////////////////
// store unit controller
///////////////////////////////////////////////////////

  // set read port to low priority
  assign rd_prio[2] = 1'b0;

  wt_dcache_wbuffer #(
    .ArianeCfg     ( ArianeCfg     )
  ) i_wt_dcache_wbuffer (
    .clk_i           ( clk_i               ),
    .rst_ni          ( rst_ni              ),
    .empty_o         ( wbuffer_empty_o     ),
    // TODO: fix this
    .cache_en_i      ( cache_en            ),
    // .cache_en_i      ( '0                  ),
    // request ports from core (store unit)
    .req_port_i      ( req_ports_i   [2]   ),
    .req_port_o      ( req_ports_o   [2]   ),
    // miss unit interface
    .miss_signature_o( miss_signature[2]   ),
    .miss_req_o      ( miss_req      [2]   ),
    .miss_ack_i      ( miss_ack      [2]   ),
    .miss_we_o       ( miss_we       [2]   ),
    .miss_wdata_o    ( miss_wdata    [2]   ),
    .miss_vld_bits_o ( miss_vld_bits [2]   ),
    .miss_paddr_o    ( miss_paddr    [2]   ),
    .miss_nc_o       ( miss_nc       [2]   ),
    .miss_size_o     ( miss_size     [2]   ),
    .miss_id_o       ( miss_id       [2]   ),
    .miss_rtrn_vld_i ( miss_rtrn_vld [2]   ),
    .miss_rtrn_id_i  ( miss_rtrn_id        ),
    // cache read interface
    .rd_tag_o        ( rd_tag        [2]   ),
    .rd_idx_o        ( rd_idx        [2]   ),
    .rd_off_o        ( rd_off        [2]   ),
    .rd_req_o        ( rd_req        [2]   ),
    .rd_tag_only_o   ( rd_tag_only   [2]   ),
    .rd_ack_i        ( rd_ack        [2]   ),
    .rd_data_i       ( rd_data             ),
    .rd_vld_bits_i   ( rd_vld_bits         ),
    .rd_hit_oh_i     ( rd_hit_oh           ),
     // incoming invalidations/cache refills
    .wr_cl_vld_i     ( wr_cl_vld           ),
    .wr_cl_idx_i     ( wr_cl_idx           ),
    // single word write interface
    .wr_req_o        ( wr_req              ),
    .wr_ack_i        ( wr_ack              ),
    .wr_idx_o        ( wr_idx              ),
    .wr_off_o        ( wr_off              ),
    .wr_data_o       ( wr_data             ),
    .wr_data_be_o    ( wr_data_be          ),
    // write buffer forwarding
    .wbuffer_data_o  ( wbuffer_data        ),
    .tx_paddr_o      ( tx_paddr            ),
    .tx_vld_o        ( tx_vld              )
  );

///////////////////////////////////////////////////////
// memory arrays, arbitration and tag comparison
///////////////////////////////////////////////////////

  wt_dcache_mem #(
    .Axi64BitCompliant ( ArianeCfg.Axi64BitCompliant ),
    .NumPorts          ( NumPorts                    )
  ) i_wt_dcache_mem (
    .clk_i             ( clk_i              ),
    .rst_ni            ( rst_ni             ),
    // read ports
    .rd_prio_i         ( rd_prio            ),
    .rd_tag_i          ( rd_tag             ),
    .rd_idx_i          ( rd_idx             ),
    .rd_off_i          ( rd_off             ),
    .rd_req_i          ( rd_req             ),
    .rd_tag_only_i     ( rd_tag_only        ),
    .rd_ack_o          ( rd_ack             ),
    .rd_vld_bits_o     ( rd_vld_bits        ),
    .rd_hit_oh_o       ( rd_hit_oh          ),
    .rd_ever_hit_o     ( rd_ever_hit        ),
    .rd_rep_way_o      ( rd_rep_way         ),
    .rd_rep_way_vld_o  ( rd_rep_way_vld     ),
    .rd_data_o         ( rd_data            ),
    // cacheline write port
    .wr_cl_vld_i       ( wr_cl_vld          ),
    .wr_cl_nc_i        ( wr_cl_nc           ),
    .wr_cl_line_upgraded_i ( wr_cl_line_upgraded ),
    .wr_cl_we_i        ( wr_cl_we           ),
    .wr_cl_tag_i       ( wr_cl_tag          ),
    .wr_cl_idx_i       ( wr_cl_idx          ),
    .wr_cl_off_i       ( wr_cl_off          ),
    .wr_cl_data_i      ( wr_cl_data         ),
    .wr_cl_data_be_i   ( wr_cl_data_be      ),
    .wr_vld_bits_i     ( wr_vld_bits        ),
    .wr_sig_we_i       ( wr_sig_we          ),
    .write_signature_i ( write_signature    ),
    .wr_cl_signature_i ( wr_cl_signature    ),
    // single word write port
    .wr_req_i          ( wr_req             ),
    .wr_ack_o          ( wr_ack             ),
    .wr_idx_i          ( wr_idx             ),
    .wr_off_i          ( wr_off             ),
    .wr_data_i         ( wr_data            ),
    .wr_data_be_i      ( wr_data_be         ),
    // write buffer forwarding
    .wbuffer_data_i    ( wbuffer_data       ),

    // output to predictor
    .pred_outcome_o    ( pred_outcome	    ),
    .pred_hit_shct_o   ( pred_hit_shct	    ),
    .pred_miss_shct_o  ( pred_miss_shct	    ),

    // output to lru
    .hit_o	       ( hit	    ),
    .hit_idx_o         ( hit_idx    ),
    .hit_way_o         ( hit_way    )
    /*.lru_mshr_o	       ( lru_mshr	    ),
    .lru_mshr_idx_o    ( lru_mshr_idx       ),
    .lru_mshr_way_o    ( lru_mshr_way	    ),
    .lru_miss_idx_o    ( lru_miss_idx	    )*/
  );

///////////////////////////////////////////////////////
// assertions
///////////////////////////////////////////////////////

// check for concurrency issues


//pragma translate_off
`ifndef VERILATOR
  flush: assert property (
    @(posedge clk_i) disable iff (!rst_ni) flush_i |-> flush_ack_o |-> wbuffer_empty_o)
     else $fatal(1,"[l1 dcache] flushed cache implies flushed wbuffer");

   initial begin
    // assert wrong parameterizations
    assert (DCACHE_INDEX_WIDTH<=12)
      else $fatal(1,"[l1 dcache] cache index width can be maximum 12bit since VM uses 4kB pages");
   end
`endif
//pragma translate_on

endmodule // wt_dcache
