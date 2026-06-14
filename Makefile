# Makefile for AnnotationSync plugin translations

DOMAIN = annotation_sync
TEMPLATE_DIR = l10n
PO_FILES = $(wildcard l10n/*/*.po)
MO_FILES = $(PO_FILES:%.po=%.mo)

MSGFMT = msgfmt
XGETTEXT = xgettext

.PHONY: all pot mo clean

all: mo

%.mo: %.po
	$(MSGFMT) --no-hash -o $@ $<

mo: $(MO_FILES)

pot:
	mkdir -p $(TEMPLATE_DIR)
	$(XGETTEXT) --from-code=utf-8 \
		--keyword=_ \
		--keyword=C_:1c,2 --keyword=N_:1,2 --keyword=NC_:1c,2,3 \
		--package-name="AnnotationSync" \
		--package-version="1.2.0" \
		--output=$(TEMPLATE_DIR)/$(DOMAIN).pot \
		*.lua

clean:
	rm -f $(MO_FILES)
