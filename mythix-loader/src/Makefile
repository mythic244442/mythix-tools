CC64 = x86_64-w64-mingw32-gcc
CC32 = i686-w64-mingw32-gcc
CFLAGS = -O2 -Wall
LDFLAGS = -lshlwapi
OUT = ..

all: $(OUT)/mythix_loader.exe $(OUT)/mythix_loader_32.exe

$(OUT)/mythix_loader.exe: mythix_loader.c
	$(CC64) $(CFLAGS) -o $@ $< $(LDFLAGS)

$(OUT)/mythix_loader_32.exe: mythix_loader.c
	$(CC32) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(OUT)/mythix_loader.exe $(OUT)/mythix_loader_32.exe

.PHONY: all clean
