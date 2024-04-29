YASM = yasm

MON_ROMS = scp-8086-monitor-1.5.rom
MON_ROMS += scp-8086-monitor-1.9.rom

ROMS = $(MON_ROMS)

all: roms emu
roms: $(ROMS)
emu: scpemu

%.rom: %.asm
	$(YASM) $(YASM_FLAGS) -o $@ $^

scpemu: scpemu.c
	$(CC) $(CFLAGS) $(LDFLAGS) -lx86emu -o $@ $^

clean:
	-rm $(ROMS)
	-rm scpemu
