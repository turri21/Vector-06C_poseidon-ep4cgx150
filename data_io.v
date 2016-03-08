//
// data_io.v
//
// io controller writable ram for the MiST board
// http://code.google.com/p/mist-board/
//
// ZX Spectrum adapted version
//
// Copyright (c) 2015 Till Harbaum <till@harbaum.org>
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

module data_io 
(
	// io controller spi interface
	input         sck,
	input         ss,
	input         sdi,

	input         force_erase,
	output        downloading,   // signal indicating an active download
   output  [4:0] index,         // menu index used to upload the file
	 
	// external ram interface
	input         clk,
	output reg    wr,
	output [24:0] addr,
	output [7:0]  dout
);

assign index = index_reg;
assign downloading = downloading_reg || erasing;
assign dout = erasing ? 8'h00      : data;
assign addr = erasing ? erase_addr : write_a;

reg [6:0]  sbuf;
reg [7:0]  cmd;
reg [7:0]  data;
reg [4:0]  cnt;

reg [24:0] waddr;
reg [24:0] write_a    = 0;
reg [24:0] erase_addr = 0;
reg rclk = 1'b0;

reg erase_trigger;

localparam UIO_FILE_TX      = 8'h53;
localparam UIO_FILE_TX_DAT  = 8'h54;
localparam UIO_FILE_INDEX   = 8'h55;

reg  [4:0] index_reg;
reg downloading_reg = 0;
reg        erasing = 0;
reg [24:0] erase_mask;

// data_io has its own SPI interface to the io controller
always@(posedge sck, posedge ss, posedge force_erase) begin
	if(force_erase) 
		index_reg <= 5'd31;
	else if(ss == 1'b1)
		cnt <= 5'd0;
	else begin
		rclk <= 1'b0;
		erase_trigger <= 1'b0;

		// don't shift in last bit. It is evaluated directly
		// when writing to ram
		if(cnt != 15)
			sbuf <= { sbuf[5:0], sdi};

		// increase target address after write
		if(rclk)
			waddr <= waddr + 25'd1;
	 
		// count 0-7 8-15 8-15 ... 
		if(cnt < 15) cnt <= cnt + 4'd1;
			else cnt <= 4'd8;

		// finished command byte
      if(cnt == 7)
			cmd <= {sbuf, sdi};

		// prepare/end transmission
		if((cmd == UIO_FILE_TX) && (cnt == 15)) begin
			// prepare 
			if(sdi) begin
				case(index_reg)
							0: waddr <= 25'h080000; // BOOT ROM
							1: waddr <= 25'h000100; // ROM file
							2: waddr <= 25'h010000; // EDD file
							3: waddr <= 25'h100000; // FDD file
					default: waddr <= 25'h000000; // C00 file
				endcase
				downloading_reg <= 1; 
			end else begin
				write_a <= waddr;
				downloading_reg <= 0; 
				if(index_reg == 1) erase_trigger <= 1;
			end
		end

		// command 0x54: UIO_FILE_TX
		if((cmd == UIO_FILE_TX_DAT) && (cnt == 15)) begin
			write_a <= waddr;
			data <= {sbuf, sdi};
			rclk <= 1'b1;
		end
		
      // expose file (menu) index
      if((cmd == UIO_FILE_INDEX) && (cnt == 15))
			index_reg <= {sbuf[3:0], sdi};
	end
end

always@(posedge clk) begin
	reg rclkD, rclkD2;
	reg eraseD, eraseD2;
	reg feraseD = 0, feraseD2 = 0;
	reg  [4:0] erase_clk_div;
	reg [24:0] end_addr;
	rclkD <= rclk;
	rclkD2 <= rclkD;
	wr <= 0;
	
	if(rclkD && !rclkD2) wr <= 1;

	eraseD <= erase_trigger;
	eraseD2 <= eraseD;

	feraseD <= force_erase;
	feraseD2 <= feraseD;
	
	// start erasing
	if(eraseD && !eraseD2) begin
		erase_clk_div <= 0;
		erase_addr <= waddr;
		erase_mask <= 25'hFFFF;
		end_addr <= 25'hFF;
		erasing <= 1;
	end else if(feraseD && !feraseD2) begin
		erase_clk_div <= 0;
		erase_addr <= 25'h1FFFFFF;
		erase_mask <= 25'h1FFFFFF;
		end_addr <= 25'h4FFFF;
		erasing <= 1;
	end else begin
		erase_clk_div <= erase_clk_div + 5'd1;
		if(!erase_clk_div) begin
			if(erase_addr != end_addr) begin
				erase_addr <= (erase_addr + 25'd1) & erase_mask;
				wr <= 1;
			end else begin
				erasing <= 0;
			end
		end
	end
end

endmodule
