//
// Vector-06C display implementation
// 
// Copyright (c) 2016 Sorgelig
//
// 
// This source file is free software: you can redistribute it and/or modify 
// it under the terms of the GNU General Public License as published 
// by the Free Software Foundation, either version 3 of the License, or 
// (at your option) any later version. 
// 
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>. 
//


`timescale 1ns / 1ps

module video
(
	input         reset,

	// Clocks
	input         clk_sys,
	input         ce_12mp,
	input         ce_12mn,

	// OSD data
	input         SPI_SCK,
	input         SPI_SS3,
	input         SPI_DI,

	// Video outputs
	output  [5:0] VGA_R,
	output  [5:0] VGA_G,
	output  [5:0] VGA_B,
	output        VGA_VS,
	output        VGA_HS,
	
	// TV/VGA
	input         scandoubler_disable,
	input         ypbpr,

	// CPU bus
	input	 [15:0] addr,
	input	  [7:0] din,
	input			  we,
	input         io_we,
	
	// Misc signals
	input   [7:0] scroll,
	input   [3:0] border,
	input         mode512,
	output        retrace
);

assign     retrace = VSync;

reg  [9:0] hc;
reg  [8:0] vc;
wire [8:0] vcr = vc + ~roll;
reg  [7:0] roll;
reg        HBlank, HSync;
reg        VBlank, VSync;
reg        viden, dot;
reg  [7:0] idx0, idx1, idx2, idx3;
wire[31:0] vram_o;

dpram vram
(
	.clock(clk_sys),
	.wraddress({addr[12:0], addr[14:13]}),
	.data(din),
	.wren(we & addr[15]),
	.rdaddress({hc[8:4], ~vcr[7:0]}),
	.q(vram_o)
);

always @(posedge clk_sys) begin
	reg [7:0] border_d;

	if(ce_12mp) begin
		if(hc == 767) begin 
			hc <=0;
			if (vc == 311) begin 
				vc <= 9'd0;
			end else begin
				vc <= vc + 1'd1;

				if(vc == 271) VBlank <= 1;
				if(vc == 271) VSync  <= 1;
				if(vc == 281) VSync  <= 0;
				if(vc == 295) VBlank <= 0;
			end
		end else hc <= hc + 1'd1;

		if((vc == 311) && (hc == 759)) roll <= scroll;
		if(hc == 563) HBlank <= 1;
		if(hc == 597) HSync  <= 1;
		if(hc == 653) HSync  <= 0;
		if(hc == 723) HBlank <= 0;
	end

	if(ce_12mn) begin
		if(hc[0]) begin
			idx0 <= {idx0[6:0], border_d[4]};
			idx1 <= {idx1[6:0], border_d[5]};
			idx2 <= {idx2[6:0], border_d[6]};
			idx3 <= {idx3[6:0], border_d[7]};
			if((hc[3:1] == 2) & ~hc[9] & ~vc[8]) {idx0, idx1, idx2, idx3} <= vram_o;

			border_d <= {border_d[3:0], border};
		end

		dot   <= ~hc[0];
		viden <= ~HBlank & ~VBlank;
	end
end

reg  [7:0] palette[16];
wire [3:0] color_idx = {{2{~(mode512 & ~dot)}} & {idx3[7], idx2[7]}, {2{~(mode512 & dot)}} & {idx1[7], idx0[7]}};

always @(posedge clk_sys) begin
	reg old_we;
	old_we <= io_we;

	if(reset) begin
		palette[0]  <= ~8'b11111111;
		palette[1]  <= ~8'b01010101;
		palette[2]  <= ~8'b11010111;
		palette[3]  <= ~8'b10000111;
		palette[4]  <= ~8'b11101010;
		palette[5]  <= ~8'b01101000;
		palette[6]  <= ~8'b11010000;
		palette[7]  <= ~8'b11000000;
		palette[8]  <= ~8'b10111101;
		palette[9]  <= ~8'b01111010;
		palette[10] <= ~8'b11000111;
		palette[11] <= ~8'b00111111;
		palette[12] <= ~8'b11101000;
		palette[13] <= ~8'b11010010;
		palette[14] <= ~8'b10010000;
		palette[15] <= ~8'b00000010;
	end else if(~old_we & io_we) begin
		palette[color_idx] <= din;
	end
end

wire [2:0] R = {3{viden}} & palette[color_idx][2:0];
wire [2:0] G = {3{viden}} & palette[color_idx][5:3];
wire [1:0] B = {2{viden}} & palette[color_idx][7:6];

wire [5:0] R_out;
wire [5:0] G_out;
wire [5:0] B_out;

osd #(10'd0, 10'd0, 3'd4) osd
(
	.*,
	.ce_pix(ce_12mp),
	.R_in({R, R}),
	.G_in({G, G}),
	.B_in({B, B, B})
);

wire       hs_out, vs_out;
wire [5:0] r_out;
wire [5:0] g_out;
wire [5:0] b_out;

scandoubler scandoubler(
	.*,
	.ce_x2(ce_12mp | ce_12mn),
	.ce_x1(ce_12mp),

	.scanlines(2'b00),

	.hs_in(HSync),
	.vs_in(VSync),
	.r_in(R_out),
	.g_in(G_out),
	.b_in(B_out)
);

video_mixer video_mixer
(
	.*,
	.ypbpr_full(1),

	.r_i({R_out, R_out[5:4]}),
	.g_i({G_out, G_out[5:4]}),
	.b_i({B_out, B_out[5:4]}),
	.hsync_i(HSync),
	.vsync_i(VSync),

	.r_p({r_out, r_out[5:4]}),
	.g_p({g_out, g_out[5:4]}),
	.b_p({b_out, b_out[5:4]}),
	.hsync_p(hs_out),
	.vsync_p(vs_out)
);


endmodule
