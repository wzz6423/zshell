.PHONY: run stop update build-package clean

run stop update build-package:
	@$(MAKE) -C mac $@

clean:
	@$(MAKE) -C mac clean
	@rm -rf web/.nitro web/.output web/.source web/.tanstack web/.vinxi web/dist
