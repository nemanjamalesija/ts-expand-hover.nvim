.PHONY: test

test:
	nvim --headless --noplugin \
	  -u tests/minimal_init.lua \
	  -c "PlenaryBustedDirectory spec/ { minimal_init = 'tests/minimal_init.lua', sequential = true }"
