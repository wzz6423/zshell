.PHONY: run stop update build-package clean format format-check

run stop update build-package:
	@$(MAKE) --no-print-directory -C mac $@

format:
	@python3 mac/scripts/format-code.py

format-check:
	@python3 mac/scripts/format-code.py --check

clean:
	@$(MAKE) --no-print-directory -C mac clean
	@rm -rf web/.nitro web/.output web/.source web/.tanstack web/.vinxi web/dist
