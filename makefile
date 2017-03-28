NIMFLAGS+=--threads:on
#NIMFLAGS+=--threadAnalysis:off
NIMFLAGS+=--verbosity:2
NIMFLAGS+=-d:debug
#NIMFLAGS+=-d:release
NIMFLAGS+=--tlsemulation:on
#NIMFLAGS+=-d:debugHeapLinks

run-main:
do: main.exe
	./main.exe
main.exe: main.nim multiproc.nim
run-%: %.exe
	./$*.exe
%.exe: %.nim
	nim ${NIMFLAGS} --out:$*.exe c $<
clean:
	rm -rf nimcache/
	rm -f main.exe
