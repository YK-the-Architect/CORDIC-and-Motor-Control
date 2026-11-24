###############################################################################
# Project layout:
#
# project/
# ├── Makefile
# ├── rtl/
# └── tb/
#
# Example:
#   make TB=fifo_tb.sv TOP=fifo_tb
#   make TB=tb/fifo_tb.sv TOP=fifo_tb
###############################################################################

# Directory containing this Makefile
MAKEFILE_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# Project source directories
RTL_DIR := $(MAKEFILE_DIR)/rtl
TB_DIR  := $(MAKEFILE_DIR)/tb

# Simulation output directory
# $(CURDIR) is the directory where make was invoked
RUN_TIMESTAMP := $(shell date +%Y%m%d_%H%M%S)
SIM_DIR := $(CURDIR)/sim_$(RUN_TIMESTAMP)

# Testbench file and top-level module
# These must be supplied on the command line
#TB  ?= tb_cordic.sv
TOP ?= tb_cordic

#ifeq ($(strip $(TB)),)
#$(error Missing testbench. Use: make TB=<testbench_file> TOP=<top_module>)
#endif

ifeq ($(strip $(TOP)),)
$(error Missing top module. Use: make TB=<testbench_file> TOP=<top_module>)
endif

# Allows either:
#   TB=fifo_tb.sv
# or:
#   TB=tb/fifo_tb.sv
#TB_FILE := $(abspath $(if $(wildcard $(MAKEFILE_DIR)/$(TB)),\
	$(MAKEFILE_DIR)/$(TB),\
	$(TB_DIR)/$(TB)))

#ifeq ($(wildcard $(TB_FILE)),)
#$(error Testbench file not found: $(TB_FILE))
#endif

# Find all Verilog and SystemVerilog files under rtl/
RTL_SRCS := $(shell find "$(RTL_DIR)" -type f \
	\( -name "*.v" -o -name "*.sv" \) -print)

TB_SRCS := $(shell find "$(TB_DIR)" -type f \
	\( -name "*.v" -o -name "*.sv" \) -print)

# Find include directories under rtl/ and tb/
INC_DIRS := $(shell find "$(RTL_DIR)" "$(TB_DIR)" -type d -print)
INC_FLAGS := $(foreach dir,$(INC_DIRS),+incdir+$(dir))

# VCS options
VCS_FLAGS := \
	-sverilog \
	-full64 \
	-debug_access+all \
	-timescale=1ns/1ps \
	$(INC_FLAGS)

.PHONY: all compile run

# Default target
all: run

# Compile RTL and the selected testbench
compile:
	@echo "Simulation output: $(SIM_DIR)"
	@mkdir -p "$(SIM_DIR)"

	@cd "$(SIM_DIR)" && vcs \
		$(VCS_FLAGS) \
		$(RTL_SRCS) \
		$(TB_SRCS)	\
		-top "$(TOP)" \
		-Mdir=./csrc \
		-o ./simv \
		-l ./compile.log

# Compile and run the simulation
run: compile
	@cd "$(SIM_DIR)" && ./simv -l simulation.log
