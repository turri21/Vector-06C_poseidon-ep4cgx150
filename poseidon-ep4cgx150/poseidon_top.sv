
module poseidon_top (

	input         CLOCK_50,


	output        LED,
	output [5:0] VGA_R,
	output [5:0] VGA_G,
	output [5:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,

`ifdef USE_HDMI
	output        HDMI_RST,
	output  [7:0] HDMI_R,
	output  [7:0] HDMI_G,
	output  [7:0] HDMI_B,
	output        HDMI_HS,
	output        HDMI_VS,
	output        HDMI_PCLK,
	output        HDMI_DE,
	output        HDMI_SDA,
	output        HDMI_SCL,
`endif

	input         SPI_SCK,
	inout         SPI_DO,
	input         SPI_DI,
	input         SPI_SS2,    // data_io
	input         SPI_SS3,    // OSD
	input         CONF_DATA0, // SPI_SS for user_io

`ifdef USE_QSPI
	input         QSCK,
	input         QCSn,
	inout   [3:0] QDAT,
`endif
//`ifndef NO_DIRECT_UPLOAD
//	input         SPI_SS4,
//`endif

	output [12:0] SDRAM_A,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nWE,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nCS,
	output  [1:0] SDRAM_BA,
	output        SDRAM_CLK,
	output        SDRAM_CKE,

`ifdef DUAL_SDRAM
	output [12:0] SDRAM2_A,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_DQML,
	output        SDRAM2_DQMH,
	output        SDRAM2_nWE,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nCS,
	output  [1:0] SDRAM2_BA,
	output        SDRAM2_CLK,
	output        SDRAM2_CKE,
`endif

	output        AUDIO_L,
	output        AUDIO_R,
//	output        DAC_L,
//	output        DAC_R,

	output        I2S_BCK,
	output        I2S_LRCK,
	output        I2S_DATA


//	input         AUDIO_IN,

//	input         UART_RX,
//	output        UART_TX
);




`ifdef BIG_OSD
localparam bit BIG_OSD = 1;
localparam SEP = "-;";
`else
localparam bit BIG_OSD = 0;
localparam SEP = "";
`endif



guest_top guest
(
 .CLOCK_50    (CLOCK_50),
 .*
);


endmodule
