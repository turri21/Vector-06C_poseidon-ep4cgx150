// ====================================================================
//                Vector 06C FPGA REPLICA
//
//            Copyright (C) 2016 Sorgelig
//
// This core is distributed under modified BSD license. 
// For complete licensing information see LICENSE.TXT.
// -------------------------------------------------------------------- 
//
// An open implementation of Vector 06C home computer
//
// Based on code from Dmitry Tselikov and Viacheslav Slavinsky
// 

`define WITH_LEDs

module Vector06
(
   input         CLOCK_27,  // Input clock 27 MHz

   output [5:0]  VGA_R,
   output [5:0]  VGA_G,
   output [5:0]  VGA_B,
   output        VGA_HS,
   output        VGA_VS,

   output        LED,

   output        AUDIO_L,
   output        AUDIO_R,

   input         SPI_SCK,
   output        SPI_DO,
   input         SPI_DI,
   input         SPI_SS2,
   input         SPI_SS3,
   input         CONF_DATA0,

   output [12:0] SDRAM_A,
   inout  [15:0] SDRAM_DQ,
   output        SDRAM_DQML,
   output        SDRAM_DQMH,
   output        SDRAM_nWE,
   output        SDRAM_nCAS,
   output        SDRAM_nRAS,
   output        SDRAM_nCS,
   output [1:0]  SDRAM_BA,
   output        SDRAM_CLK,
   output        SDRAM_CKE
);

///////////////   MIST ARM I/O   /////////////////
assign LED = ~(ioctl_download | fdd_rd);

wire scandoubler_disable;
wire ps2_kbd_clk, ps2_kbd_data;

wire  [7:0] status;
wire  [1:0] buttons;
wire  [7:0] joyA;
wire  [7:0] joyB;

wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_data;
wire        ioctl_download;
wire  [4:0] ioctl_index;

mist_io #(.STRLEN(97)) user_io 
(
	.conf_str
	(
	     "VECTOR06;ROM;F2,EDD;F3,FDD;O4,Turbo,Off,On;O7,Reset Palette,Yes,No;T5,Enter to App;T6,Cold Reboot"
	),
	.SPI_SCK(SPI_SCK),
	.CONF_DATA0(CONF_DATA0),
	.SPI_DO(SPI_DO),
	.SPI_DI(SPI_DI),

	.status(status),
	.buttons(buttons),
	.scandoubler_disable(scandoubler_disable),

	.joystick_0(joyA),
	.joystick_1(joyB),
	.ps2_clk(clk_ps2),
	.ps2_kbd_clk(ps2_kbd_clk),
	.ps2_kbd_data(ps2_kbd_data),

	.SPI_SS2(SPI_SS2),
	.force_erase(cold_reset),
	.downloading(ioctl_download),
	.index(ioctl_index),
	.clk(clk_sys),
	.wr(ioctl_wr),
	.addr(ioctl_addr),
	.dout(ioctl_data)
);

////////////////////   CLOCKS   ///////////////////
wire locked;
pll pll
(
	.inclk0(CLOCK_27),
	.locked(locked),
	.c0(clk_ram),
	.c1(SDRAM_CLK),
	.c2(clk_sys),
	.c3(clk_psg)
);

wire clk_sys;       // 24Mhz
wire clk_ram;       // 96MHz
wire clk_psg;       // 1.75MHz
reg  clk_pit;       // 1.5MHz
                    //
                    // strobes:
reg  clk_f1, clk_f2;// 3MHz/6MHz
reg  clk_ps2;       // 14KHz

always @(negedge clk_sys) begin
	reg [4:0] div = 0;
	reg turbo;
	int ps2_div;

	div <= div + 1'd1;
	clk_pit <= div[3];
	turbo <= (div[2:0] == 7) & status[4];

	if(turbo) begin
		clk_f1 <= (div[2:0] == 0) | (div[2:0] == 4);
		clk_f2 <= (div[2:0] == 2) | (div[2:0] == 6);
		cpu_ready <= 1;
	end else begin
		clk_f1 <= div[2:0] == 0;
		clk_f2 <= div[2:0] == 4;
		if(div[4:2]==3'b100) cpu_ready <= 1;
			else if(!div[2:0] & cpu_sync & mreq) cpu_ready <= 0;
	end

	ps2_div <= ps2_div+1;
	if(ps2_div == 856) begin 
		ps2_div <=0;
		clk_ps2 <= ~clk_ps2;
	end
end

////////////////////   RESET   ////////////////////
reg cold_reset = 0;
reg reset = 1;
reg rom_enable = 1;

//wait for boot rom
integer reset_timer = 15000000;

wire RESET = status[0] | status[5] | status[6] | buttons[1] | reset_key[0];
reg  first_cycle = 1;

always @(posedge clk_sys) begin
	if (RESET || ioctl_download || reset_timer) begin
		if(status[6]) reset_timer <= 100;
		reset <=1;
		rom_enable <=(rom_enable & ~((ioctl_download & (ioctl_index == 1)) | reset_key[2] | status[5]));
		if(first_cycle) rom_enable <=1;
		first_cycle <=0;
		if(reset_timer) reset_timer <= reset_timer - 1;
		if(reset_timer == 20) cold_reset <= 1;
	end else begin
		cold_reset <=0;
		first_cycle <=1;
		reset <=0;
	end
end

////////////////////   CPU   ////////////////////
wire [15:0] addr;
reg   [7:0] cpu_i;
wire  [7:0] cpu_o;
wire        cpu_sync;
wire        cpu_rd;
wire        cpu_wr_n;
reg         cpu_ready;
wire        cpu_inte;
reg         cpu_int;

reg   [7:0] status_word;
always @(posedge cpu_sync) status_word <= cpu_o;

wire int_ack  = status_word[0];
wire write_n  = status_word[1];
wire io_stack = status_word[2];
//wire halt_ack = status_word[3];
wire io_write = status_word[4];
//wire m1       = status_word[5];
wire io_read  = status_word[6];
wire ram_read = status_word[7];

wire mreq = (ram_read | ~write_n) & ~io_write & ~io_read;

reg ppi1_sel, joy_sel, vox_sel, pit_sel, pal_sel, psg_sel, edsk_sel, fdd_sel;

reg [7:0] io_data;
always_comb begin
	ppi1_sel =0;
	joy_sel  =0;
	vox_sel  =0;
	pit_sel  =0;
	pal_sel  =0;
	edsk_sel =0;
	psg_sel  =0;
	fdd_sel  =0;
	io_data  =255;
	casex(addr[7:0])
		8'b000000XX: begin ppi1_sel =1; io_data = ppi1_o;  end
		8'b0000010X: begin joy_sel  =1; io_data = 0;       end 
		8'b00000110: begin              io_data = joyP_o;  end
		8'b00000111: begin vox_sel  =1; io_data = joyPU_o; end
		8'b000010XX: begin pit_sel  =1; io_data = pit_o;   end
		8'b0000110X: begin pal_sel  =1;                    end
		8'b00001110: begin pal_sel  =1; io_data = joyA_o;  end
		8'b00001111: begin pal_sel  =1; io_data = joyB_o;  end
		8'b00010000: begin edsk_sel =1;                    end
		8'b0001010X: begin psg_sel  =1; io_data = psg_o;   end
		8'b00011XXX: begin fdd_sel  =fdd_ready; if(!addr[2] && fdd_ready) io_data = fdd_o; end
		    default: ;
	endcase
end

always_comb begin
	casex({int_ack, io_read, rom_enable && !rom_size && !ed_page && !addr[15:11]})
		 3'b001: cpu_i = rom_o;
		 3'b01X: cpu_i = io_data;
		 3'b1XX: cpu_i = 255;
		default: cpu_i = ram_o;
	endcase
end

wire io_rd = io_read  & cpu_rd;
wire io_wr = io_write & ~cpu_wr_n;

k580vm80a cpu
(
   .pin_clk(clk_sys),
   .pin_f1(clk_f1),
   .pin_f2(clk_f2),
   .pin_reset(reset),
   .pin_a(addr),
   .pin_dout(cpu_o),
   .pin_din(cpu_i),
   .pin_hold(0),
   .pin_ready(cpu_ready),
   .pin_int(cpu_int),
   .pin_inte(cpu_inte),
   .pin_sync(cpu_sync),
   .pin_dbin(cpu_rd),
   .pin_wr_n(cpu_wr_n)
);

////////////////////   MEM   ////////////////////
wire[7:0] ram_o;
sram sram
( 
	.*,
	.init(!locked),
	.clk_sdram(clk_ram),
	.dout(ram_o),
	.din( ioctl_download ? ioctl_data : cpu_o),
	.addr(ioctl_download ? ioctl_addr : fdd_read ? fdd_addr : {read_rom, ed_page, addr}),
	.we(  ioctl_download ? ioctl_wr   : ~cpu_wr_n & ~io_write),
	.rd(  ioctl_download ? 1'b0       : cpu_rd)
);

reg  [15:0] rom_size = 0;
wire read_rom = rom_enable && (addr<rom_size) && !ed_page && ram_read;
always @(negedge ioctl_download) if(!ioctl_index) rom_size <= ioctl_addr[15:0];

wire [7:0] rom_o;
bios rom(.address(addr[10:0]), .clock(clk_sys), .q(rom_o));

/////////////////  E-DISK 256KB  ///////////////////
reg  [2:0] ed_page;
reg  [7:0] ed_reg;

wire edsk_we = io_wr & edsk_sel;
always @(posedge edsk_we, posedge reset) begin
	if(reset) ed_reg <= 0;
		else ed_reg <= cpu_o;
end

wire ed_win   = addr[15] & ((addr[13] ^ addr[14]) | (ed_reg[7] & addr[13] & addr[14]) | (ed_reg[6] & ~addr[13] & ~addr[14]));
wire ed_ram   = ed_reg[5] & ed_win   & (ram_read | ~write_n);
wire ed_stack = ed_reg[4] & io_stack & (ram_read | ~write_n);

always_comb begin
	casex({ed_stack, ed_ram, ed_reg[3:0]})
		6'b1X00XX, 6'b01XX00: ed_page = 1;
		6'b1X01XX, 6'b01XX01: ed_page = 2;
		6'b1X10XX, 6'b01XX10: ed_page = 3;
		6'b1X11XX, 6'b01XX11: ed_page = 4;
		             default: ed_page = 0;
	endcase
end

/////////////////////   FDD   /////////////////////
wire  [7:0] fdd_o;
wire [20:0] fdd_addr;
wire        fdd_drive;
reg         fdd_ready;
wire        fdd_rd;
wire        fdd_wr;
reg  [24:0] fdd_size;

always @(negedge ioctl_download, posedge cold_reset) begin 
	if(cold_reset) begin
		fdd_ready <= 0;
		fdd_size  <= 0;
	end else if(ioctl_index == 3) begin 
		fdd_ready <= 1;
		fdd_size  <= ioctl_addr - 25'h100000;
	end
end

wire fdd_read = fdd_rd & io_read & fdd_sel;
assign fdd_addr[20] = 1;

wd1793 fdd
(
	.clk(clk_f1),
	.reset(reset),
	.rd(fdd_sel & io_rd),
	.wr(fdd_sel & io_wr),
	.addr({addr[2],~addr[1:0]}),
	.idata(cpu_o),
	.odata(fdd_o),

	.buff_size(fdd_size[19:0]),
	.buff_addr(fdd_addr[19:0]),
	.buff_read(fdd_rd),
	.buff_write(fdd_wr),
	.buff_idata(ram_o),

	.oDRIVE(fdd_drive),
	.iDISK_READY(fdd_drive ? 1'b0 : fdd_ready)
);

////////////////////   VIDEO   ////////////////////
wire retrace;

video video
(
	.*,
	.reset(reset & ~status[7]),
	.clk_24m(clk_sys),
	.addr(addr),
	.din(cpu_o),
	.we(~cpu_wr_n && ~io_write && !ed_page),
	
	.scroll(ppi1_a),
	.io_we(pal_sel & io_wr),
	.border(ppi1_b[3:0]),
	.mode512(ppi1_b[4]),
	.retrace(retrace)
);

always @(posedge retrace, negedge cpu_inte) begin
	if(!cpu_inte) cpu_int <= 0;
		else cpu_int <= 1;
end

////////////////////   KBD   ////////////////////
wire [7:0] kbd_o;
wire [2:0] kbd_shift;
wire [2:0] reset_key;

rk_kbd kbd
(
	.clk(clk_sys), 
	.reset(cold_reset),
	.ps2_clk(ps2_kbd_clk),
	.ps2_dat(ps2_kbd_data),
	.addr(~ppi1_a), 
	.odata(kbd_o), 
	.shift(kbd_shift),
	.reset_key(reset_key)
);

//////////////////  PPI1 (SYS)  ///////////////////
wire [7:0] ppi1_o;
wire [7:0] ppi1_a;
wire [7:0] ppi1_b;
wire [7:0] ppi1_c;

k580vv55 ppi1
(
	.reset(0), 
	.addr(~addr[1:0]), 
	.we_n(~(io_wr & ppi1_sel)),
	.idata(cpu_o), 
	.odata(ppi1_o), 
	.opa(ppi1_a),
	.ipb(~kbd_o),
	.opb(ppi1_b),
	.ipc({~kbd_shift,tapein,4'b1111}),
	.opc(ppi1_c)
);

/////////////////   Joystick Zoo   /////////////////

wire [7:0] joyPU   = joyA | joyB;
wire [7:0] joyPU_o = {joyPU[3], joyPU[0], joyPU[2], joyPU[1], joyPU[4], joyPU[5], 2'b00};

wire [7:0] joyA_o  = ~{joyA[5], joyA[4], 2'b00, joyA[2], joyA[3], joyA[1], joyA[0]};
wire [7:0] joyB_o  = ~{joyB[5], joyB[4], 2'b00, joyB[2], joyB[3], joyB[1], joyB[0]};

reg  [7:0] joy_port;
wire joy_we = io_wr & joy_sel;
always @(posedge joy_we, posedge reset) begin
	if(reset) joy_port <= 0;
	else begin 
		if(addr[0]) joy_port <= cpu_o;
			else if(!cpu_o[7]) joy_port[cpu_o[3:1]] <= cpu_o[0];
	end
end

reg [7:0] joyP_o;
always_comb begin
	case(joy_port[6:5]) 
		2'b00: joyP_o = joyA_o & joyB_o;
		2'b01: joyP_o = joyA_o;
		2'b10: joyP_o = joyB_o;
		2'b11: joyP_o = 255;
	endcase
end

////////////////////   SOUND   ////////////////////
wire tapein = 1'b0;

wire [7:0] pit_o;
wire [2:0] pit_out;
wire [2:0] pit_active;
wire [2:0] pit_snd = pit_out & pit_active;

k580vi53 pit
(
	.reset(reset),
	.clk_sys(clk_sys),
	.clk_timer({clk_pit,clk_pit,clk_pit}),
	.addr(~addr[1:0]),
	.wr(io_wr & pit_sel),
	.rd(io_rd & pit_sel),
	.din(cpu_o),
	.dout(pit_o),
	.gate(3'b111),
	.out(pit_out),
	.sound_active(pit_active)
);

wire [1:0] legacy_audio = 2'd0 + ppi1_c[0] + pit_snd[0] + pit_snd[1] + pit_snd[2];

wire [7:0] psg_o;
wire [7:0] psg_ch_a;
wire [7:0] psg_ch_b;
wire [7:0] psg_ch_c;
wire [5:0] psg_active;

ym2149 ym2149
(
	.CLK(clk_psg),
	.RESET(reset),
	.BDIR(io_wr & psg_sel),
	.BC(addr[0]),
	.DI(cpu_o),
	.DO(psg_o),
	.CHANNEL_A(psg_ch_a),
	.CHANNEL_B(psg_ch_b),
	.CHANNEL_C(psg_ch_c),
	.ACTIVE(psg_active),
	.SEL(0),
	.MODE(0)
);

integer covox_timeout;
always @(posedge clk_sys) begin
	if(reset | rom_enable) covox_timeout <= 50000000;
		else if(covox_timeout) covox_timeout <= covox_timeout -1;
end

reg  [7:0] covox;
wire       covox_mute = (covox_timeout != 0);
wire       vox_we = io_wr & vox_sel & ~covox_mute;
always @(posedge vox_we, posedge reset) begin
	if(reset) covox <= 0;
		else covox <= cpu_o;
end

sigma_delta_dac #(.MSBI(10)) dac_l
(
	.CLK(clk_sys),
	.RESET(reset),
	.DACin(psg_active ? {1'b0, psg_ch_a, 1'b0} + {2'b00, psg_ch_b} + {1'b0, legacy_audio, 7'd0} : {1'b0, legacy_audio, 8'd0} + {1'b0, covox, 1'b0}),
	.DACout(AUDIO_L)
);

sigma_delta_dac #(.MSBI(10)) dac_r
(
	.CLK(clk_sys),
	.RESET(reset),
	.DACin(psg_active ? {1'b0, psg_ch_c, 1'b0} + {2'b00, psg_ch_b} + {1'b0, legacy_audio, 7'd0} : {1'b0, legacy_audio, 8'd0} + {1'b0, covox, 1'b0}),
	.DACout(AUDIO_R)
);

endmodule
