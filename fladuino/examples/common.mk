# The user must specify paths to Fladuino and Arduino.
FLADUINO_DIR= ../../../fladuino
ARDUINO_DIR = ../../../arduino-dist
POLOLU_DIR = ../../../pololu-dist


## 
# Default setting
##

# Default to the name of the current directory for the program name.
ifndef PROGNAME
PROGNAME = $(notdir $(CURDIR))
endif

# If no device has been specified, default to Duemilanove.
ifndef PLATFORM
PLATFORM = mega
endif

ifndef VENDOR
VENDOR = arduino
endif

ifndef UPLOAD_RATE
UPLOAD_RATE = 57600
endif

ifndef PORT
PORT = /dev/ttyUSB0
endif

ifndef AVRDUDE_PROGRAMMER
AVRDUDE_PROGRAMMER = stk500v1
endif

# Supportet platforms that can safely be compiled to.
PLATFORMS = duemilanove bt mega 3pi

# Supportet platform vendors 
VENDORS = arduino pololu


## 
# Overwrite defualt settings if the chosen platform requires so.
##

ifeq ($(PLATFORM), duemilanove)
MCU = atmega328p
endif
ifeq ($(PLATFORM), 3pi)
MCU = atmega168
AVRDUDE_PROGRAMMER = avrisp2
VENDOR = pololu
UPLOAD_RATE = 115200
endif
ifeq ($(PLATFORM), bt)
MCU = atmega168
UPLOAD_RATE = 115200
PORT = /dev/rfcomm0
endif
ifeq ($(PLATFORM), mega)
MCU = atmega1280
endif


############################################################################
# Below here nothing should be changed...

ifeq ($(filter $(PLATFORM), $(PLATFORMS)),)
$(warning Platform $(PLATFORM) is not supportet. If proper settings is set, this might work. Supportet Platforms is: $(PLATFORMS))
endif

ifeq ($(filter $(VENDOR), $(VENDORS)),)
$(error Vendor $(VENDOR) is not supportet. Must be either of: $(VENDORS))
endif




# Fladuino specifics
FLADUINO_RUNTIME=$(FLADUINO_DIR)/runtime
FLADUINO_PRELUDE=$(FLADUINO_RUNTIME)/Prelude.hs
FLADUINO_FLAGS = --platform $(PLATFORM)

# Pololu specifics
POLOLU = $(POLOLU_DIR)

# Arduino specifics
ARDUINO = $(ARDUINO_DIR)/hardware/arduino/cores/arduino


ARDUINO_SRC =  $(ARDUINO)/pins_arduino.c                                        \
$(ARDUINO)/wiring.c                                                             \
$(ARDUINO)/wiring_analog.c                                                      \
$(ARDUINO)/wiring_digital.c                                                     \
$(ARDUINO)/wiring_pulse.c                                                       \
$(ARDUINO)/wiring_shift.c                                                       \
$(ARDUINO)/WInterrupts.c
ARDUINO_CXXSRC = $(ARDUINO)/HardwareSerial.cpp                                  \
$(ARDUINO)/WMath.cpp $(ARDUINO)/Print.cpp

ARDUINO_CDEFS = 
ARDUINO_CSSDEFS = 

ARDUINO_CINCS = -I$(ARDUINO)
ARDUINO_CXXINCS = -I$(ARDUINO)


POLOLU_SRC = 
POLOLU_CXXSRC = $(POLOLU_DIR)/src/OrangutanAnalog/OrangutanAnalog.cpp			\
$(POLOLU_DIR)/src/Pololu3pi/Pololu3pi.cpp                                               \
$(POLOLU_DIR)/src/OrangutanTime/OrangutanTime.cpp	                                \
$(POLOLU_DIR)/src/OrangutanResources/OrangutanResources.cpp				\
$(POLOLU_DIR)/src/OrangutanSerial/OrangutanSerial.cpp					\
$(POLOLU_DIR)/src/OrangutanPushbuttons/OrangutanPushbuttons.cpp				\
$(POLOLU_DIR)/src/OrangutanMotors/OrangutanMotors.cpp					\
$(POLOLU_DIR)/src/OrangutanLEDs/OrangutanLEDs.cpp					\
$(POLOLU_DIR)/src/PololuQTRSensors/PololuQTRSensors.cpp					\
$(POLOLU_DIR)/src/OrangutanLCD/OrangutanLCD.cpp						\
$(POLOLU_DIR)/src/OrangutanBuzzer/OrangutanBuzzer.cpp					\
$(POLOLU_DIR)/src/PololuWheelEncoders/PololuWheelEncoders.cpp

# The pololu library needs this definition to compile. 
POLOLU_CDEFS = -DLIB_POLOLU 
POLOLU_CXXDEFS = -DLIB_POLOLU

# We also want to be able to use Arduino functions such as digitalWrite etc.
# Though there could potentially be a problem if we end up including Arduino 
# time and Pololu time handling, so be carefull.
POLOLU_CINCS = -I$(POLOLU) -I$(ARDUINO)
POLOLU_CXXINCS = -I$(POLOLU) -I$(ARDUINO)


ifeq ($(VENDOR), arduino)
SRC = $(ARDUINO_SRC)
CXXSRC = $(ARDUINO_CXXSRC)
else ifeq ($(VENDOR), pololu)
SRC = $(ARDUINO_SRC) $(POLOLU_SRC)
CXXSRC = $(ARDUINO_CXXSRC) $(POLOLU_CXXSRC)
endif


FORMAT = ihex

AVR_TOOLS_PATH = /usr/bin

TARGET = $(PROGNAME)
F_CPU = 16000000

# Name of this Makefile (used for "make depend").
MAKEFILE = Makefile

# Debugging format.
# Native formats for AVR-GCC's -g are stabs [default], or dwarf-2.
# AVR (extended) COFF requires stabs, plus an avr-objcopy run.
DEBUG = stabs

# Optimize flag. s for size.
OPT = s

# Place -D or -U options here
CDEFS = -DF_CPU=$(F_CPU) $(ARDUINO_CDEFS) $(POLOLU_CDEFS)
CXXDEFS = -DF_CPU=$(F_CPU) $(ARDUINO_CXXDEFS) $(POLOLU_CXXDEFS)

# Place -I options here
CINCS = -I$(FLADUINO_RUNTIME) $(ARDUINO_CINCS) $(POLOLU_CINCS)
CXXINCS = $(ARDUINO_CXXINCS) $(POLOLU_CXXINCS)


# Compiler flag to set the C Standard level.
# c89   - "ANSI" C
# c99   - ISO C99 standard (not yet fully implemented)
# gnu89 - c89 plus GCC extensions
# gnu99 - c99 plus GCC extensions
CSTANDARD = -std=gnu99
CDEBUG = -g$(DEBUG)
CWARN = -Wall -Wstrict-prototypes
CTUNING = -funsigned-char -funsigned-bitfields -fpack-struct -fshort-enums
#CEXTRA = -Wa,-adhlns=$(<:.c=.lst)

CFLAGS = $(CDEBUG) $(CDEFS) $(CINCS) -O$(OPT) $(CWARN) $(CSTANDARD) $(CEXTRA)
CXXFLAGS = $(CXXDEFS) $(CXXINCS) -O$(OPT)
#ASFLAGS = -Wa,-adhlns=$(<:.S=.lst),-gstabs 
LDFLAGS = -lm


# Programming support using avrdude. Settings and variables.
AVRDUDE_PORT = $(PORT)
AVRDUDE_WRITE_FLASH = -U flash:w:applet/$(TARGET).hex

ifeq ($(VENDOR), arduino)
AVRDUDE_FLAGS = -v -D -C $(ARDUINO_DIR)/hardware/tools/avrdude.conf \
-p $(MCU) -P $(AVRDUDE_PORT) -c $(AVRDUDE_PROGRAMMER) \
-b $(UPLOAD_RATE)
else ifeq ($(VENDOR), pololu)
# We dont want to disable erase (-D) of the chip for the pololu robots
# since they dont have a bootloader.
AVRDUDE_FLAGS = -v -C $(ARDUINO_DIR)/hardware/tools/avrdude.conf \
-p $(MCU) -P $(AVRDUDE_PORT) -c $(AVRDUDE_PROGRAMMER) \
-b $(UPLOAD_RATE)
endif


# Program settings
CC = $(AVR_TOOLS_PATH)/avr-gcc
CXX = $(AVR_TOOLS_PATH)/avr-g++
OBJCOPY = $(AVR_TOOLS_PATH)/avr-objcopy
OBJDUMP = $(AVR_TOOLS_PATH)/avr-objdump
AR  = $(AVR_TOOLS_PATH)/avr-ar
SIZE = $(AVR_TOOLS_PATH)/avr-size
NM = $(AVR_TOOLS_PATH)/avr-nm
AVRDUDE = $(ARDUINO_DIR)/hardware/tools/avrdude
REMOVE = rm -f
MV = mv -f

# Define all object files.
OBJ = $(SRC:.c=.o) $(CXXSRC:.cpp=.o) $(ASRC:.S=.o) 

# Define all listing files.
LST = $(ASRC:.S=.lst) $(CXXSRC:.cpp=.lst) $(SRC:.c=.lst)

# Combine all necessary flags and optional flags.
# Add target processor to flags.
ALL_CFLAGS = -mmcu=$(MCU) -I. $(CFLAGS) $(POLOLU_CFLAGS)
ALL_CXXFLAGS = -mmcu=$(MCU) -I. $(CXXFLAGS) $(POLOLU_CXXFLAGS)
ALL_ASFLAGS = -mmcu=$(MCU) -I. -x assembler-with-cpp $(ASFLAGS)

#fladuinoall
all:  fladuinoall $(VENDOR)all
clean: fladuinoclean arduinoclean

# Fladuino part of the compilation.
fladuinoall: Main.hs
	mkdir -p obj
	ghc --make -odir obj -hidir obj -o fladuinogen -W \
	    $<
	./fladuinogen $(FLADUINO_FLAGS) --prelude $(FLADUINO_PRELUDE) -o $(PROGNAME)

fladuinoclean:
	rm -rf obj fladuinogen *.dump.* $(PROGNAME).pde

# Arduino part of the compilation
arduinoall: applet_files build sizeafter

arduinoclean:
	$(REMOVE) applet/$(TARGET).hex applet/$(TARGET).eep applet/$(TARGET).cof applet/$(TARGET).elf \
	applet/$(TARGET).map applet/$(TARGET).sym applet/$(TARGET).lss applet/core.a \
	$(OBJ) $(LST) $(SRC:.c=.s) $(SRC:.c=.d) $(CXXSRC:.cpp=.s) $(CXXSRC:.cpp=.d)

pololuall: applet_files build sizeafter

pololuclean:
	$(REMOVE) applet/$(TARGET).hex applet/$(TARGET).eep applet/$(TARGET).cof applet/$(TARGET).elf \
	applet/$(TARGET).map applet/$(TARGET).sym applet/$(TARGET).lss applet/core.a \
	$(OBJ) $(LST) $(SRC:.c=.s) $(SRC:.c=.d) $(CXXSRC:.cpp=.s) $(CXXSRC:.cpp=.d)

build: elf hex 

applet_files:$(TARGET).pde
	# Here is the "preprocessing".
	# It creates a .cpp file based with the same name as the .pde file.
	# On top of the new .cpp file comes the WProgram.h header.
	# At the end there is a generic main() function attached.
	# Then the .cpp file will be compiled. Errors during compile will
	# refer to this new, automatically generated, file. 
	# Not the original .pde file you actually edit...
	test -d applet || mkdir applet
	echo '#include "WProgram.h"' > applet/$(TARGET).cpp
	cat $(TARGET).pde >> applet/$(TARGET).cpp
	cat $(ARDUINO)/main.cpp >> applet/$(TARGET).cpp

elf: applet/$(TARGET).elf
hex: applet/$(TARGET).hex
eep: applet/$(TARGET).eep
lss: applet/$(TARGET).lss 
sym: applet/$(TARGET).sym

# Program the device.  
upload: applet/$(TARGET).hex
	$(AVRDUDE) $(AVRDUDE_FLAGS) $(AVRDUDE_WRITE_FLASH)


	# Display size of file.
HEXSIZE = $(SIZE) --target=$(FORMAT) applet/$(TARGET).hex
ELFSIZE = $(SIZE)  applet/$(TARGET).elf
sizebefore:
	@if [ -f applet/$(TARGET).elf ]; then echo; echo $(MSG_SIZE_BEFORE); $(HEXSIZE); echo; fi

sizeafter:
	@if [ -f applet/$(TARGET).elf ]; then echo; echo $(MSG_SIZE_AFTER); $(HEXSIZE); echo; fi


# Convert ELF to COFF for use in debugging / simulating in AVR Studio or VMLAB.
COFFCONVERT=$(OBJCOPY) --debugging \
--change-section-address .data-0x800000 \
--change-section-address .bss-0x800000 \
--change-section-address .noinit-0x800000 \
--change-section-address .eeprom-0x810000 


coff: applet/$(TARGET).elf
	$(COFFCONVERT) -O coff-avr applet/$(TARGET).elf $(TARGET).cof


extcoff: $(TARGET).elf
	$(COFFCONVERT) -O coff-ext-avr applet/$(TARGET).elf $(TARGET).cof


.SUFFIXES: .elf .hex .eep .lss .sym

.elf.hex:
	# .elf.hex
	$(OBJCOPY) -O $(FORMAT) -R .eeprom $< $@

.elf.eep:
	-$(OBJCOPY) -j .eeprom --set-section-flags=.eeprom="alloc,load" \
	--change-section-lma .eeprom=0 -O $(FORMAT) $< $@

# Create extended listing file from ELF output file.
.elf.lss:
	$(OBJDUMP) -h -S $< > $@

# Create a symbol table from ELF output file.
.elf.sym:
	$(NM) -n $< > $@


applet/$(TARGET).elf: $(TARGET).pde applet/core.a 
	# Link: create ELF output file from library.
	$(CC) $(ALL_CFLAGS) -o $@ applet/$(TARGET).cpp -L. applet/core.a $(LDFLAGS)

applet/core.a: $(OBJ)
	@for i in $(OBJ); do echo $(AR) rcs applet/core.a $$i; $(AR) rcs applet/core.a $$i; done



# Compile: create object files from C++ source files.
.cpp.o:
	$(CXX) -c $(ALL_CXXFLAGS) $< -o $@ 

# Compile: create object files from C source files.
.c.o:
	$(CC) -c $(ALL_CFLAGS) $< -o $@ 


# Compile: create assembler files from C source files.
.c.s:
	$(CC) -S $(ALL_CFLAGS) $< -o $@


# Assemble: create object files from assembler source files.
.S.o:
	$(CC) -c $(ALL_ASFLAGS) $< -o $@

# Automatic dependencies
%.d: %.c
	$(CC) -M $(ALL_CFLAGS) $< | sed "s;$(notdir $*).o:;$*.o $*.d:;" > $@

%.d: %.cpp
	$(CXX) -M $(ALL_CXXFLAGS) $< | sed "s;$(notdir $*).o:;$*.o $*.d:;" > $@


.PHONY:	all arduinoall fladuinoall pololuall \
	clean arduinoclean fladuinoclean pololuclean \
	build elf hex eep lss sym program \
	coff extcoff applet_files sizebefore sizeafter
