# Indiana WIDA ACCESS 2026–27 standard-setting impact deck — build pipeline
#
#   make            # incremental build (caches rebuilt only if inputs changed)
#   make force      # force-rebuild both caches, then render
#   make cache      # (re)build both summary caches
#   make render     # render the deck only (assumes caches exist)
#   make clean      # remove rendered HTML + freeze/cache dirs (keeps summary/)

QMD      := WIDA_IN_Standard_Setting_Impact.qmd
HTML     := docs/index.html
CONC     := summary/concordance_summary.rds
IMPACT   := summary/in_wida_impact_summary.rds

export WIDA_CONCORDANCE_XLSX
export WIDA_IN_DATA_DIR
export WIDA_SCALE_XFORM
export ILEARN_EXIT_CSV

.PHONY: all force cache render clean

all: render

$(CONC):
	Rscript R/01_concordance_summary.R

$(IMPACT): $(CONC)
	Rscript R/02_impact_summary.R

cache: $(CONC) $(IMPACT)

force:
	Rscript R/01_concordance_summary.R --force
	Rscript R/02_impact_summary.R --force
	$(MAKE) render

render: $(CONC) $(IMPACT)
	quarto render $(QMD)
	mkdir -p docs
	mv -f index.html docs/index.html
	rm -rf index_files

clean:
	rm -f $(HTML) index.html
	rm -rf .quarto index_files index_cache \
	       WIDA_IN_Standard_Setting_Impact_files WIDA_IN_Standard_Setting_Impact_cache
