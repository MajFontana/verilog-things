module UartTx
#(
	parameter real CLOCK_FREQUENCY=100000000,
	parameter real BAUD=56000,
	parameter integer BUFFER_SIZE=8
)
(
	input RST,
	input CLK,
	input [7:0] DATA,
	input WRITE,

	output WRITE_READY,
	output reg TX
);
	
	//////// Parameters ////////
	
	// UART clock divider
	parameter integer uart_interval = CLOCK_FREQUENCY / BAUD; // UART bit duration in clock cycles
	
	// Output buffer
	parameter integer pos_reg_size = $clog2(BUFFER_SIZE + 1); // Size of buffer position registers
	
	
	
	//////// Declarations ////////
	
	// UART clock divider
	reg [$clog2(uart_interval) - 1'd1:0] tx_clk_counter; // UART clock divider counter
	wire tx_strobe; // UART strobe
	
	// Output buffer
	reg [7:0] buffer [0:BUFFER_SIZE]; // Buffer memory
	reg [pos_reg_size - 1:0] pos_write; // Buffer write (input) pointer
	reg [pos_reg_size - 1:0] pos_tx; // Buffer read (TX) pointer
	reg [pos_reg_size - 1:0] pos_write_next; // Pointer to next write location, for buffer full detection
	wire write_ready; // Status - write ready, empty location available
	wire tx_ready; // Status - read ready, data to be transmitted available
	
	// UART transmitter
	reg [3:0] uart_state;
	wire waiting; // Status - waiting for data to transmit



	//////// Design logic ////////

	// UART clock divider
	assign tx_strobe = !tx_clk_counter;

	always @(posedge CLK or posedge RST) begin
		if (RST) begin
			tx_clk_counter <= uart_interval - 1'd1;
		end
		else begin
			if (waiting) begin
				tx_clk_counter <= 1'd1;
			end
			else begin
				if (!tx_clk_counter) begin
					tx_clk_counter <= uart_interval - 1'd1;
				end
				else begin
					tx_clk_counter <= tx_clk_counter - 1'd1;
				end
			end
		end
	end
	
	// Output buffer	
	assign write_ready = pos_write_next != pos_tx;
	assign tx_ready = pos_write != pos_tx;
	assign WRITE_READY = write_ready;
	
	always @(*) begin
		if (!pos_write) begin
			pos_write_next = BUFFER_SIZE;
		end
		else begin
			pos_write_next = pos_write - 1'd1;
		end
	end

	always @(posedge CLK or posedge RST) begin
		if (RST) begin
			pos_write <= BUFFER_SIZE;
		end
		else begin
			if (write_ready & WRITE) begin
				buffer[pos_write] <= DATA;
				if (!pos_write) begin
					pos_write <= BUFFER_SIZE;
				end
				else begin
					pos_write <= pos_write - 1'd1;
				end
			end
		end
	end

	// UART transmitter
	assign waiting = uart_state == 4'd9;
	
	always @(posedge CLK or posedge RST) begin
		if (RST) begin
			uart_state <= 4'd8;
			pos_tx <= BUFFER_SIZE;
			TX <= 1'd1;
		end
		else begin
			case (uart_state)
				4'd7: begin
					if (tx_strobe) begin
						TX <= buffer[pos_tx][uart_state];
						uart_state <= 4'd8;
						if (!pos_tx) begin
							pos_tx <= BUFFER_SIZE;
						end
						else begin
							pos_tx <= pos_tx - 1'd1;
						end
					end
				end
				4'd8: begin
					if (tx_strobe) begin
						TX <= 1'd1;
						uart_state <= 4'd9;
					end
				end
				4'd9: begin
					if (tx_ready) begin
						uart_state <= 4'd10;
					end
				end
				4'd10: begin
					if (tx_strobe) begin
						TX <= 1'd0;
						uart_state <= 4'd0;
					end
				end
				default: begin
					if (tx_strobe) begin
						TX <= buffer[pos_tx][uart_state];
						uart_state <= uart_state + 1'd1;
					end
				end
			endcase
		end
	end

endmodule



module UartRx
#(
	parameter real CLOCK_FREQUENCY=100000000,
	parameter real BAUD=56000,
	parameter integer BUFFER_SIZE=8,
	parameter integer SAMPLE_SIZE=16
)
(
	input RST,
	input CLK,
	input READ,
	input RX,
	
	output [7:0] DATA,
	output READ_READY
);
	
	//////// Parameters ////////
	
	// Sampling clock divider
	parameter integer sampling_interval = CLOCK_FREQUENCY / BAUD / SAMPLE_SIZE; // Time between samples in clock cycles
	
	// Sampler
	parameter integer window_size_half = (SAMPLE_SIZE / 2.0); // Half of the size of the window, used for clock synchronization and as a filtering threshold

	// Input buffer
	parameter integer pos_reg_size = $clog2(BUFFER_SIZE + 1); // Size of buffer position registers
	
	
	
	//////// Declarations ////////
	
	// Sampling clock divider
	reg [$clog2(sampling_interval) - 1'd1:0] sampling_clk_counter; // Sampling clock divider counter
	wire sample_strobe; // Sampling strobe
	
	// UART clock divider
	reg [$clog2(SAMPLE_SIZE) - 1'd1:0] uart_clk_counter; // UART clock divider counter
	wire rx_strobe; // UART strobe
	
	// Sampler
	reg rx_sample; // Sampled RX line
	reg [SAMPLE_SIZE - 1:0] sample_window; // Shift register for samples
	reg [$clog2(SAMPLE_SIZE + 1'd1) - 1:0] ones_count; // Stores count of high readings (1s) in the window
	reg rx_filtered_old; // Old RX window reading, for edge detection
	wire rx_filtered; // Filtered RX window reading, whether the count of high readings exceedes the threshold
	wire falling_edge; // Status - falling edge in filtered RX input
	
	// Input buffer
	reg [7:0] buffer [0:BUFFER_SIZE];
	reg [pos_reg_size - 1:0] pos_read; // Buffer output (read) position
	reg [pos_reg_size - 1:0] pos_rx; // Buffer input (RX) position
	reg [pos_reg_size - 1:0] pos_rx_next; // Next buffer input position, for buffer full detection
	wire read_ready; // Status - data to read available in buffer
	wire rx_ready; // Status - space for new data available in buffer
	
	// UART receiver
	reg [3:0] uart_state;
	reg [7:0] frame_data; // Shift register for receieved bits
	wire waiting; // Status - receiver is waiting for a new frame
	
	
	
	//////// Design logic ////////

	// Sampling clock divider
	assign sample_strobe = !sampling_clk_counter;

	always @(posedge CLK or posedge RST) begin
		if (RST) begin
			sampling_clk_counter <= sampling_interval - 1'd1;
		end
		else begin
			if (!sampling_clk_counter) begin
				sampling_clk_counter <= sampling_interval - 1'd1;
			end
			else begin
				sampling_clk_counter <= sampling_clk_counter - 1'd1;
			end
		end
	end

	// UART clock divider
	assign rx_strobe = !uart_clk_counter & sample_strobe;

	always @(posedge CLK or posedge RST) begin
		if (RST) begin
			uart_clk_counter <= SAMPLE_SIZE - 1'd1;
		end
		else begin
			if (sample_strobe) begin
				if (waiting) begin
					uart_clk_counter <= window_size_half - 1;
				end
				else begin
					if (!uart_clk_counter) begin
						uart_clk_counter <= SAMPLE_SIZE - 1'd1;
					end
					else begin
						uart_clk_counter <= uart_clk_counter - 1'd1;
					end
				end
			end
		end
	end
	
	// Sampler
	assign rx_filtered = ones_count >= window_size_half;
	assign falling_edge = ~rx_filtered & rx_filtered_old;
	
	always @(posedge CLK or posedge RST) begin
		if (RST) begin
			sample_window <= 1'd0;
			ones_count <= 1'd0;
			rx_filtered_old <= 1'd0;
			rx_sample <= 1'd1;
		end
		else begin
			if (sample_strobe) begin
				rx_sample <= RX;
				ones_count <= ones_count + rx_sample - sample_window[SAMPLE_SIZE - 1];
				sample_window <= {sample_window, rx_sample};
				rx_filtered_old <= rx_filtered;
			end
		end
	end
	
	// Input buffer
	assign read_ready = pos_rx != pos_read;
	assign rx_ready = pos_rx_next != pos_read;
	assign READ_READY = read_ready;
	assign DATA = buffer[pos_read];

	always @(*) begin
		if (!pos_rx) begin
			pos_rx_next = BUFFER_SIZE;
		end
		else begin
			pos_rx_next = pos_rx - 1'd1;
		end
	end

	always @(posedge CLK or posedge RST) begin
		if (RST) begin
			pos_read <= BUFFER_SIZE;
		end
		else begin
			if (read_ready & READ) begin
				if (!pos_read) begin
					pos_read <= BUFFER_SIZE;
				end
				else begin
					pos_read <= pos_read - 1'd1;
				end
			end
		end
	end
	
	// UART receiver
	
	assign waiting = uart_state == 4'd9;
	
	always @(posedge CLK or posedge RST) begin
		if (RST) begin
			uart_state <= 4'd9;
			pos_rx <= BUFFER_SIZE;
		end
		else begin
			case (uart_state)
				4'd8: begin
					if (rx_strobe) begin
						if (rx_ready & rx_filtered) begin
							buffer[pos_rx] <= frame_data;
							if (!pos_rx) begin
								pos_rx <= BUFFER_SIZE;
							end
							else begin
								pos_rx <= pos_rx - 1'd1;
							end
						end
						uart_state <= 4'd9;
					end
				end	
				4'd9: begin
					if (falling_edge) begin
						uart_state <= 4'd10;
					end
				end
				4'd10: begin
					if (rx_strobe) begin
						if (~rx_filtered) begin
							uart_state <= 4'd0;
						end
						else begin
							uart_state <= 4'd9;
						end
					end
				end
				default: begin
					if (rx_strobe) begin
						frame_data <= {rx_filtered, frame_data[7:1]};
						uart_state <= uart_state + 1'd1;
					end
				end
			endcase
		end
	end

endmodule
