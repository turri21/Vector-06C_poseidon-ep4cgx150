`default_nettype none

// ====================================================================
//                        VECTOR-06C FPGA REPLICA
//
//             Copyright (C) 2007,2008 Viacheslav Slavinsky
//
// This core is distributed under modified BSD license. 
// For complete licensing information see LICENSE.TXT.
// -------------------------------------------------------------------- 
//
// An open implementation of Vector-06C home computer
//
// Author: Viacheslav Slavinsky, http://sensi.org/~svo
// 
// Design File: wd1793.v
//
// This module approximates the inner workings of a WD1793 floppy disk
// controller to some minimal extent. Track read/write operations
// are not supported, other ops are mimicked only barely enough.
//
// --------------------------------------------------------------------
//
// Modified version by Sorgelig to work with image in RAM
//
//

// In Vector, addresses are inverted, as usual
//                WD			VECTOR
//COMMAND/STATUS	000		011	
//DATA 				011		000
//TRACK				001		010
//SECTOR				010		001
//CTL2			  				111 
module wd1793
(
	input        clk,			 // clock: e.g. 3MHz
	input        reset,	 	 // async reset
	input        rd,			 // i/o read
	input        wr,			 // i/o write
	input  [2:0] addr,		 // i/o port addr
	input  [7:0] idata,		 // i/o data in
	output [7:0] odata,		 // i/o data out

	// Sector buffer access signals
	input [19:0] buff_size,	 // buffer RAM address
	output[19:0] buff_addr,	 // buffer RAM address
	output       buff_read,	 // buffer RAM read enable
	output       buff_write, // buffer RAM write enable
	input  [7:0] buff_idata, // buffer RAM data input
	output [7:0] buff_odata, // buffer RAM data output

	output       oDRIVE,		 // DRIVE (A/B)
	input        iDISK_READY // =1 - disk is present
);

reg  [7:0] q;
assign odata = q;

reg  [9:0] byte_addr;
wire [7:0] off1 = {disk_track[6:0], ~wdstat_side};
wire [9:0] off2 = {off1, 2'b00} + off1 + wdstat_sector - 1'd1;
assign     buff_addr = {off2, byte_addr};

reg  buff_rd, buff_wr;
assign buff_read  = ((addr == A_DATA) && buff_rd);
assign buff_write = ((addr == A_DATA) && buff_wr);

assign buff_odata = idata;
assign oDRIVE = wdstat_drive;

// Register addresses				
parameter A_COMMAND	= 3'b000;
parameter A_STATUS	= 3'b000;
parameter A_TRACK 	= 3'b001;
parameter A_SECTOR	= 3'b010;
parameter A_DATA		= 3'b011;
parameter A_CTL2		= 3'b111; 		/* port $1C: bit0 = drive #, bit2 = head# */

// States
parameter STATE_READY 		= 4'd0;	/* Initial, idle, sector data read */
parameter STATE_WAIT_READ	= 4'd1;	/* wait until read operation completes -> STATE_READ_2/STATE_READY */
parameter STATE_WAIT			= 4'd2;	/* NOP operation wait -> STATE_READY */
parameter STATE_ABORT		= 4'd3;	/* Abort current command ($D0) -> STATE_READY */
parameter STATE_READ_2   	= 4'd4;	/* Buffer-to-host: wait before asserting DRQ -> STATE_READ_3 */
parameter STATE_READ_3		= 4'd5;	/* Buffer-to-host: load data into reg, assert DRQ -> STATE_READY */
parameter STATE_WAIT_WRITE	= 4'd6;	/* wait until write operation completes -> STATE_READY */
parameter STATE_READ_1		= 4'd7;	/* Buffer-to-host: increment data pointer, decrement byte count -> STATE_READ_2*/
parameter STATE_WRITE_1		= 4'd8;	/* Host-to-buffer: wr = 1 -> STATE_WRITE_2 */
parameter STATE_WRITE_2		= 4'd9;	/* Host-to-buffer: wr = 0, next addr -> STATE_WRITESECT/STATE_WAIT_WRITE */
parameter STATE_WRITESECT	= 4'd10; /* Host-to-buffer: wait data from host -> STATE_WRITE_1 */
parameter STATE_READSECT	= 4'd11; /* Buffer-to-host */
parameter STATE_WAIT_2		= 4'd12;

parameter STATE_ENDCOMMAND	= 4'd14; /* All commands end here -> STATE_ENDCOMMAND2 */
parameter STATE_DEAD		   = 4'd15; /* Total cessation, for debugging */

// Fixed parameters that should be variables
parameter SECTOR_SIZE 		= 11'd1024;
parameter SECTORS_PER_TRACK = 8'd5;


// State variables
reg  [7:0] 	wdstat_track;
reg  [7:0]	wdstat_sector;
wire [7:0]	wdstat_status;
reg  [7:0]	wdstat_datareg;
reg  [7:0]	wdstat_command;			// command register
reg			wdstat_pending;			// command loaded, pending execution
reg 			wdstat_stepdirection;	// last step direction
reg			wdstat_multisector;		// indicates multisector mode
reg			wdstat_side;				// current side
reg			wdstat_drive;				// current drive

reg  [7:0]	disk_track;					// "real" heads position
reg  [10:0]	data_rdlength;				// this many bytes to transfer during read/write ops
reg  [3:0]	state;						// teh state

// common status bits
reg			s_readonly = 0, s_crcerr;
reg			s_headloaded, s_seekerr, s_index;  // mode 1
reg			s_lostdata, s_wrfault; 			     // mode 2,3

// Command mode 0/1 for status register
reg 			cmd_mode;

// DRQ/BUSY are always going together
reg	[1:0]	s_drq_busy;
wire			s_drq  = s_drq_busy[1];
wire			s_busy = s_drq_busy[0];

// Timer for keeping DRQ pace
reg [3:0] 	read_timer;

// Reusable expressions
wire 	    	wStepDir   = wdstat_command[6] ? wdstat_command[5] : wdstat_stepdirection;
wire [7:0]  wNextTrack = wStepDir ? disk_track - 8'd1 : disk_track + 8'd1;

wire [10:0]	wRdLengthMinus1 = data_rdlength - 1'b1;
wire [10:0]	wBuffAddrPlus1  = byte_addr + 1'b1;

// Status register
assign  wdstat_status = cmd_mode == 0 ? 	
	{~iDISK_READY, s_readonly, s_headloaded, s_seekerr, s_crcerr, !disk_track, s_index, s_busy | wdstat_pending} :
	{~iDISK_READY, s_readonly, s_wrfault,    s_seekerr, s_crcerr, s_lostdata,  s_drq,   s_busy | wdstat_pending};
	
// Watchdog	
reg	watchdog_set;
wire	watchdog_bark;
watchdog	dogbert(.clk(clk), .cock(watchdog_set), .q(watchdog_bark));

reg read_type;
reg [7:0] read_addr[6];

always @* begin
	case (addr)
		A_TRACK:  q = wdstat_track;
		A_SECTOR: q = wdstat_sector;
		A_STATUS: q = wdstat_status;
		A_CTL2:	  q = {5'b11111,wdstat_side,1'b0,wdstat_drive};
		A_DATA:	  q = (state == STATE_READY) ? wdstat_datareg : buff_rd ? buff_idata : read_addr[byte_addr[2:0]];
		default:  q = 8'hff;
	endcase
end

always @(posedge clk or posedge reset) begin: _wdmain
	reg old_wr, old_rd;
	reg [2:0] cur_addr;
	reg read_data, write_data;
	integer wait_time;

	if(reset) begin
		read_data <= 0;
		write_data <= 0;
		wdstat_multisector <= 0;
		wdstat_stepdirection <= 0;
		disk_track <= 8'hff;
		wdstat_track <= 0;
		wdstat_sector <= 0;
		{wdstat_side,wdstat_drive} <= 2'b00;
		data_rdlength <= 0;
		byte_addr <=0;
		{buff_rd,buff_wr} <= 0;
		wdstat_multisector <= 1'b0;
		state <= STATE_READY;
		cmd_mode <= 1'b0;
		{s_headloaded, s_seekerr, s_crcerr, s_index} <= 0;
		{s_wrfault, s_lostdata} <= 0;
		s_drq_busy <= 2'b00;
		wdstat_pending <= 0;
		watchdog_set <= 0;
	end else if (state == STATE_DEAD) begin
		s_drq_busy <= 2'b11;
		s_seekerr <= 1;
		s_wrfault <= 1;
		s_crcerr <= 1;
	end else begin
		old_wr <=wr;
		old_rd <=rd;

		if((!old_rd && rd) || (!old_wr && wr)) cur_addr <= addr;

		//Register read operations
		if(old_rd && !rd && (cur_addr == A_STATUS)) s_index <=0;

		//end of data reading
		if(old_rd && !rd && (cur_addr == A_DATA)) read_data <=1;

		//end of data writing
		if(old_wr && !wr && (cur_addr == A_DATA)) write_data <=1;

		/* Register write operations */
		if (!old_wr & wr) begin
			case (addr)
				A_TRACK:
					if (!s_busy) begin
						wdstat_track <= idata;
					end 

				A_SECTOR: 
					if (!s_busy) begin
						wdstat_sector <= idata;
					end

				A_CTL2: {wdstat_side, wdstat_drive} <= {idata[2], idata[0]};

				A_COMMAND:
					if (idata[7:4] == 4'hD) begin
						// interrupt
						cmd_mode <= 0;

						if (state != STATE_READY) state <= STATE_ABORT;
							else {s_wrfault,s_seekerr,s_crcerr,s_lostdata} <= 0;

					end else begin
						if (wdstat_pending) begin
							wdstat_sector <= idata;
							wdstat_track  <= {2'b00,s_drq_busy,state};
							state <= STATE_DEAD;
						end else begin
							wdstat_command <= idata;
							wdstat_pending <= 1;
						end
					end

				A_DATA: wdstat_datareg <= idata;

				default:;
			endcase
		end

		//////////////////////////////////////////////////////////////////
		// Generic state machine is described below, but some important //
		// transitions are defined within the read/write section.       //
		//////////////////////////////////////////////////////////////////

		/* Data transfer: buffer to host. Read stage 1: increment address */
		case (state) 

		/* Idle state or buffer to host transfer */
		STATE_READY:
			begin
				// handle command
				if (wdstat_pending) begin
					wdstat_pending <= 0;
					cmd_mode <= wdstat_command[7];		// keep cmd_mode for wdstat_status
					
					case (wdstat_command[7:4]) 
					4'h0: 	// RESTORE
						begin
							// head load as specified, index, track0
							s_headloaded <= wdstat_command[3];
							s_index <= 1'b1;
							wdstat_track <= 0;
							disk_track <= 0;

							// some programs like it when FDC gets busy for a while
							s_drq_busy <= 2'b01;
							state <= STATE_WAIT;
						end
					4'h1:	// SEEK
						begin
							// set real track to datareg
							disk_track <= wdstat_datareg; 
							s_headloaded <= wdstat_command[3];
							s_index <= 1'b1;
							
							// get busy 
							s_drq_busy <= 2'b01;
							state <= STATE_WAIT;
						end
					4'h2,	// STEP
					4'h3,	// STEP & UPDATE
					4'h4,	// STEP-IN
					4'h5,	// STEP-IN & UPDATE
					4'h6,	// STEP-OUT
					4'h7:	// STEP-OUT & UPDATE
						begin
							// if direction is specified, store it for the next time
							if (wdstat_command[6] == 1) wdstat_stepdirection <= wdstat_command[5]; // 0: forward/in
							
							// perform step 
							disk_track <= wNextTrack;
									
							// update TRACK register too if asked to
							if (wdstat_command[4]) wdstat_track <= wNextTrack;
								
							s_headloaded <= wdstat_command[3];
							s_index <= 1'b1;

							// some programs like it when FDC gets busy for a while
							s_drq_busy <= 2'b01;
							state <= STATE_WAIT;
						end
					4'h8, 4'h9: // READ SECTORS
						// seek data
						// 4: m:	0: one sector, 1: until the track ends
						// 3: S: 	SIDE
						// 2: E:	some 15ms delay
						// 1: C:	check side matching?
						// 0: 0
						begin
							// side is specified in the secondary control register ($1C)
							s_drq_busy <= 2'b01;
							{s_wrfault,s_seekerr,s_crcerr,s_lostdata} <= 0;
							
							wdstat_multisector <= wdstat_command[4];
							data_rdlength <= SECTOR_SIZE;
							state <= STATE_WAIT_READ;
							read_type <=1;
						end
					4'hA, 4'hB: // WRITE SECTORS
						begin
							s_drq_busy <= 2'b11;
							{s_wrfault,s_seekerr,s_crcerr,s_lostdata} <= 0;
							wdstat_multisector <= wdstat_command[4];
							
							data_rdlength <= SECTOR_SIZE;
							byte_addr <= 0;
							write_data <= 0;
							buff_wr <=1;

							state <= STATE_WRITESECT;
						end								
					4'hC:	// READ ADDRESS
						begin
							// track, side, sector, sector size code, 2-byte checksum (crc?)
							s_drq_busy <= 2'b01;
							{s_wrfault,s_seekerr,s_crcerr,s_lostdata} <= 0;

							wdstat_multisector <= 1'b0;
							state <= STATE_WAIT_READ;
							data_rdlength <= 6;
							read_type <=0;

							read_addr[0] <= disk_track;
							read_addr[1] <= {7'b0, ~wdstat_side};
							read_addr[2] <= wdstat_sector;
							read_addr[3] <= 8'd3;
							read_addr[4] <= 8'd0;
							read_addr[5] <= 8'd0;
						end
					4'hE,	// READ TRACK
					4'hF:	// WRITE TRACK
							s_drq_busy <= 2'b00;
					default:s_drq_busy <= 2'b00;
					endcase
				end
			end

		STATE_WAIT_READ:
			begin
				// s_ready == 0 means that in fact SD card was removed or some 
				// other kind of unrecoverable error has happened
				if (!iDISK_READY) begin
					// FAIL
					s_seekerr <= 1;
					s_crcerr <= 1;
					state <= STATE_ENDCOMMAND;
				end else begin
					buff_rd <= read_type;
					byte_addr <=0;
					state <= STATE_READ_2;
				end
			end
		STATE_READ_1:
			begin
				// increment data pointer, decrement byte count
				byte_addr <= wBuffAddrPlus1[9:0];
				data_rdlength <= wRdLengthMinus1[9:0];
				state <= STATE_READ_2;
			end
		STATE_READ_2:
			begin
				watchdog_set <= 1;
				read_timer <= 4'b1111;
				state <= STATE_READ_3;
				s_drq_busy <= 2'b01;
			end
		STATE_READ_3:
			begin
				if (read_timer != 0) 
					read_timer <= read_timer - 1'b1;
				else begin
					read_data <=0;
					watchdog_set <= 0;
					s_lostdata <= 1'b0;
					s_drq_busy <= 2'b11;
					state <= STATE_READSECT;
				end
			end
		STATE_READSECT:
			begin
				// lose data if not requested in time
				//if (s_drq && watchdog_bark) begin
				//	s_lostdata <= 1'b1;
				//	s_drq_busy <= 2'b01;
				//	state <= data_rdlength != 0 ? STATE_READ_1 : STATE_ABORT;
				//end

				if (watchdog_bark || (read_data && s_drq)) begin
					// reset drq until next byte is read, nothing is lost
					s_drq_busy <= 2'b01;
					s_lostdata <= watchdog_bark;
					
					if (wRdLengthMinus1 == 0) begin
						// either read the next sector, or stop if this is track end
						if (wdstat_multisector && (wdstat_sector < SECTORS_PER_TRACK)) begin
							wdstat_sector <= wdstat_sector + 1'b1;
							data_rdlength <= SECTOR_SIZE;
							state <= STATE_WAIT_READ;
						end else begin
							wdstat_multisector <= 1'b0;
							state <= STATE_ENDCOMMAND;
						end
					end else begin
						// everything is okay, fetch next byte
						state <= STATE_READ_1;
					end
				end
			end

		STATE_WAIT_WRITE:
			begin
				if (!iDISK_READY) begin
					s_wrfault <= 1;
					state <= STATE_ENDCOMMAND;
				end else begin
					if (wdstat_multisector && wdstat_sector < SECTORS_PER_TRACK) begin
						wdstat_sector <= wdstat_sector + 1'b1;
						s_drq_busy <= 2'b11;
						data_rdlength <= SECTOR_SIZE;
						byte_addr <= 0;
						state <= STATE_WRITESECT;
					end else begin
						wdstat_multisector <= 1'b0;
						state <= STATE_ENDCOMMAND;
					end
				end
			end
		STATE_WRITESECT:
			begin
				if (write_data) begin
					s_drq_busy <= 2'b01;			// busy, clear drq
					s_lostdata <= 1'b0;
					state <= STATE_WRITE_2;
					write_data <=0;
				end
			end
		STATE_WRITE_2:
			begin
				// increment data pointer, decrement byte count
				byte_addr <= wBuffAddrPlus1[9:0];
				data_rdlength <= wRdLengthMinus1;
								
				if (wRdLengthMinus1 == 0) begin
					// Flush data --
					state <= STATE_WAIT_WRITE;
				end else begin
					s_drq_busy <= 2'b11;		// request next byte
					state <= STATE_WRITESECT;
				end				
			end

		// Abort current operation ($D0)
		STATE_ABORT:
			begin
				data_rdlength <= 0;
				wdstat_pending <= 0;
				state <= STATE_ENDCOMMAND;
			end

		STATE_WAIT:
			begin
				wait_time = 40000;
				state <= STATE_WAIT_2;
			end
		STATE_WAIT_2:
			begin
				if(wait_time) wait_time <= wait_time - 1;
					else state <= STATE_ENDCOMMAND;
			end

		// End any command.
		STATE_ENDCOMMAND:
			begin
				{buff_rd,buff_wr} <= 0;
				state <= STATE_READY;
				s_drq_busy <= 2'b00;
			end
		endcase
	end
end
endmodule


// start ticking when cock goes down
module watchdog
(
	input  clk, 
	input  cock,
	output q
);

parameter TIME = 16'd2048; // 2048 seems to work better than expected 100 (32us).. why?
assign q = (timer == 0);

reg [15:0] timer;

always @(posedge clk) begin
	if (cock) begin
		timer <= TIME;
	end else begin
		if (timer != 0) timer <= timer - 1'b1;
	end
end

endmodule
