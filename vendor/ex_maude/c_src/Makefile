# ExMaude C-Node Bridge Makefile
#
# Compiles the maude_bridge C-Node binary that communicates
# with the Erlang VM using Erlang distribution protocol.
#
# The ei library is part of erl_interface and is still supported in OTP 29.
# Only the old erl_ prefixed API was removed in OTP 23.

# Detect erl_interface location
# Use halt(0) on success, halt(1) on failure to properly set exit code
EI_DIR := $(shell erl -noshell -eval 'case code:lib_dir(erl_interface) of {error,_} -> halt(1); Path -> io:format("~s", [Path]), halt(0) end' 2>/dev/null)

# Check if erl_interface was found
ifeq ($(EI_DIR),)
# erl_interface not available - provide helpful message and skip compilation

$(warning )
$(warning ========================================)
$(warning  erl_interface library not found!)
$(warning  C-Node backend will not be available.)
$(warning ========================================)
$(warning )
$(warning Your Erlang installation may not include erl_interface.)
$(warning )
$(warning On macOS with Homebrew:)
$(warning   brew reinstall erlang)
$(warning )
$(warning On Debian/Ubuntu:)
$(warning   apt install erlang-dev)
$(warning )
$(warning On Fedora/RHEL:)
$(warning   dnf install erlang-devel)
$(warning )

.PHONY: all clean info install

all:
	@echo "Skipping C-Node compilation (erl_interface not available)"
	@echo "The Port backend will still work."

clean:
	@echo "Nothing to clean (C-Node was not compiled)"

info:
	@echo "erl_interface: NOT FOUND"
	@echo "C-Node compilation: DISABLED"

install: all

else
# erl_interface IS available - proceed with compilation

# Find ERTS include path for erl_nif.h and other headers
ERTS_INCLUDE := $(shell erl -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)]), halt().' 2>/dev/null)

# Erlang Interface paths
EI_INCLUDE := $(EI_DIR)/include
EI_LIB := $(EI_DIR)/lib

# Compiler settings
# -D_REENTRANT is required for OTP 21+ to use __erl_errno_place() instead of __erl_errno symbol
CC ?= cc
CFLAGS ?= -O2
CFLAGS += -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations -D_REENTRANT -isystem $(EI_INCLUDE) -isystem $(ERTS_INCLUDE)
LDFLAGS += -L$(EI_LIB) -lei -lpthread

UNAME_S := $(shell uname -s)

# Target binary (goes in priv/)
PRIV_DIR := ../priv
TARGET := $(PRIV_DIR)/maude_bridge

# Source files
SRCS := maude_bridge.c
OBJS := $(SRCS:.c=.o)

# Default target
.PHONY: all clean info install

all: $(TARGET)
	@:

# Create priv directory if needed
$(PRIV_DIR):
	@mkdir -p $(PRIV_DIR)

# Link the binary
$(TARGET): $(OBJS) | $(PRIV_DIR)
	$(CC) -o $@ $(OBJS) $(LDFLAGS)
	@echo "Built: $@"

.PHONY: test
test: maude_bridge_test
	./maude_bridge_test

maude_bridge_test: maude_bridge_test.c maude_bridge.c Makefile
	$(CC) $(CFLAGS) -UNDEBUG -o $@ maude_bridge_test.c $(LDFLAGS)

# Compile C files
%.o: %.c Makefile
	$(CC) $(CFLAGS) -c $< -o $@

# Clean build artifacts
clean:
	rm -f $(OBJS) $(TARGET) maude_bridge_test

# Install target (for mix compile)
install: all

# Debug build with symbols
debug: CFLAGS += -g -DDEBUG -O0
debug: clean all

# Show configuration (for debugging build issues)
info:
	@echo "Platform:     $(UNAME_S)"
	@echo "EI_DIR:       $(EI_DIR)"
	@echo "EI_INCLUDE:   $(EI_INCLUDE)"
	@echo "EI_LIB:       $(EI_LIB)"
	@echo "ERTS_INCLUDE: $(ERTS_INCLUDE)"
	@echo "CC:           $(CC)"
	@echo "CFLAGS:       $(CFLAGS)"
	@echo "LDFLAGS:      $(LDFLAGS)"
	@echo "TARGET:       $(TARGET)"
	@echo ""
	@echo "ei.h exists:  $$(test -f $(EI_INCLUDE)/ei.h && echo YES || echo NO)"
	@echo "libei exists: $$(test -f $(EI_LIB)/libei.a && echo YES || echo NO)"

# Lint C code with clang-tidy (optional)
lint:
	@if command -v clang-tidy >/dev/null 2>&1; then \
		clang-tidy $(SRCS) -- $(CFLAGS); \
	else \
		echo "clang-tidy not found, skipping lint"; \
	fi

# Format check with clang-format (optional)
format-check:
	@if command -v clang-format >/dev/null 2>&1; then \
		clang-format --dry-run --Werror $(SRCS) $(wildcard maude_bridge_test.c); \
	else \
		echo "clang-format not found, skipping format check"; \
	fi

# Format code with clang-format
format:
	@if command -v clang-format >/dev/null 2>&1; then \
		clang-format -i $(SRCS) $(wildcard maude_bridge_test.c); \
	else \
		echo "clang-format not found"; \
	fi

endif
