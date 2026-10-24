# GNU make only: patsubst, foreach, define/call, $(shell), a pattern rule,
# and a sub-make; recipes in BusyBox's sh (mkdir -p, echo, a for loop).
NAMES := one two
SRCS := $(foreach n,$(NAMES),src/$(n).c)
OBJS := $(patsubst src/%.c,out/%.o,$(SRCS))
define say
@echo "$(1): $(2)"
endef

all: out/hello.exe
	$(call say,objects,$(OBJS))
	@$(MAKE) --no-print-directory -f sub.mk

out/%.o: src/%.c
	@mkdir -p out
	cc -c -O2 -o $@ $<

out/hello.exe: $(OBJS) src/main.c
	cc -O2 -s -Wl,-Brepro -o $@ $^

install: all
	mkdir -p "$(PREFIX)/bin"
	cp out/hello.exe "$(PREFIX)/bin/"
	for f in $(NAMES); do echo $$f; done > "$(PREFIX)/names.txt"
	echo "$(shell echo shell works)" > "$(PREFIX)/shell.txt"
	cp out/sub.txt "$(PREFIX)/"
