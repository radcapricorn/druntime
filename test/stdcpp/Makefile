include ../common.mak

TESTS:=array

.PHONY: all clean

# osx32 does not link properly, nobody uses it anyway...
ifeq ($(OS)$(MODEL), osx32)

all:

clean:

else
all: $(addprefix $(ROOT)/,$(addsuffix .done,$(TESTS)))

$(ROOT)/%.done : $(ROOT)/%
	@echo Testing $*
	$(QUIET)$(TIMELIMIT)$(ROOT)/$* $(RUN_ARGS)
	@touch $@

$(ROOT)/%: $(SRC)/%_test.d $(SRC)/%.cpp
	mkdir -p $(dir $@)
	$(QUIET)$(CXX) $(CXXFLAGS) -c -o $(ROOT)/$*_cpp.o $(SRC)/$*.cpp
	$(QUIET)$(DMD) $(DFLAGS) -main -unittest -of$@ $< $(ROOT)/$*_cpp.o

clean:
	rm -rf $(GENERATED)
endif
