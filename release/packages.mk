# packages.mk
#
# packages.mk is responsible for compiling packages.yml to packages.lock
# by expanding its packages using all defaults and templates.

SHELL := /usr/bin/env bash -euo pipefail -c

THIS_FILE := $(lastword $(MAKEFILE_LIST))

# SPEC is the human-managed description of which packages we are able to build.
SPEC := packages.yml
# LOCK is the generated fully-expanded rendition of SPEC, for use in generating CI
# pipelines and other things.
LOCK := packages.lock

# Temporary files.
TEMPLATE_DIR := .tmp/templates
DEFAULTS_DIR := .tmp/defaults
RENDERED_DIR := .tmp/rendered
PACKAGES_DIR := .tmp/packages
COMMANDS_DIR := .tmp/commands
LIST := .tmp/list.yml

# Count the packages we intend to list.
PKG_COUNT := $(shell yq '.packages | length' < $(SPEC))
# Try to speed things up by running all pipelines in parallel.
MAKEFLAGS += -j$(PKG_COUNT)

# Ensure the temp directories exist.
$(shell mkdir -p \
	$(TEMPLATE_DIR) \
	$(DEFAULTS_DIR) \
	$(RENDERED_DIR) \
	$(PACKAGES_DIR) \
	$(COMMANDS_DIR) \
)

# PKG_INDEXES is just the numbers 1..PKG_COUNT, we use this to generate filenames
# for the intermediate files DEFAULTS, RENDERED, PACKAGES and COMMANDS.
PKG_INDEXES := $(shell seq $(PKG_COUNT))
DEFAULTS := $(addprefix $(DEFAULTS_DIR)/,$(addsuffix .json,$(PKG_INDEXES)))
RENDERED := $(addprefix $(RENDERED_DIR)/,$(addsuffix .json,$(PKG_INDEXES)))
PACKAGES := $(addprefix $(PACKAGES_DIR)/,$(addsuffix .json,$(PKG_INDEXES)))
COMMANDS := $(addprefix $(COMMANDS_DIR)/,$(addsuffix .sh,$(PKG_INDEXES)))

TEMPLATE_NAMES := $(shell yq -r '.templates | keys[]' < $(SPEC))
TEMPLATES := $(addprefix $(TEMPLATE_DIR)/,$(TEMPLATE_NAMES))

## PHONY targets for human use.

# list generates the fully expanded package list, this is usually
# what you want.
list: $(LIST)
	@cat $<

# lock updates the lock file with the fully expanded list.
lock: $(LOCK)
	@echo "$< updated."

commands: $(COMMANDS)
	@echo done

# Other phony targets below are for debugging purposes, allowing you
# to run just part of the pipeline.
packages: $(PACKAGES)
	@cat $^

rendered: $(RENDERED)
	@cat $^

defaults: $(DEFAULTS)
	@cat $^

templates: $(TEMPLATES)
	@echo Templates updated: $^

.PHONY: list lock packages rendered defaults templates

## END PHONY targets.

# TEMPLATES writes out a file for each template in the spec, so we can refer to them
# individually later.
$(TEMPLATE_DIR)/%: $(SPEC) $(THIS_FILE)
	@echo -n '{{$$d := (datasource "vars")}}{{with $$d}}' > $@; \
		yq -r ".templates.$*" $< >> $@; \
		echo "{{end}}" >> $@

# DEFAULTS are generated by this rule, they contain just the packages listed in
# SPEC plus default values to fill in any gaps. These are used as the data source
# to the templates above for rendering.
$(DEFAULTS_DIR)/%.json: $(SPEC) $(THIS_FILE)
	@yq -c '[ .defaults as $$defaults | .packages[$*-1] | $$defaults + . ][]' < $(SPEC) > $@

# RENDERED files are generated by this rule. These files contain just the
# rendered template values for each of the DEFAULTS files we created above.
# We manually build up a YAML map in the file, then dump it out to JSON for
# use by the PACKAGES targets.
$(RENDERED_DIR)/%.json: $(DEFAULTS_DIR)/%.json $(TEMPLATES)
	@OUT=$@.yml; \
	find $(TEMPLATE_DIR) -mindepth 1 -maxdepth 1 | while read -r T; do \
	  TNAME=$$(basename $$T); \
	  echo -n "$$TNAME: " >> $$OUT; \
	  cat $< | gomplate -f $$T -d vars=$< | xargs >> $$OUT; \
	done; \
	yq . < $$OUT > $@; rm -f $$OUT

# PACKAGES files are created by this rule. They contain a merge of DEFAULTS plus
# rendered template files. Each file is a complete package spec.
# We also generate a unique PACKAGE_SPEC_ID here, which is a hash of the
# generated YAML file (prior to adding this line to it). This serves as part of the
# input identifier for a build.
$(PACKAGES_DIR)/%.json: $(DEFAULTS_DIR)/%.json $(RENDERED_DIR)/%.json 
	@jq -s '.[0] + .[1]' $^ | yq -y . > $@
	@echo "PACKAGE_SPEC_ID: $$(sha256sum < $@ | cut -d' ' -f1)" >> $@
	@yq . < $@ | sponge $@

# COMMANDS files are created by this rule. They are one-line shell scripts that can
# be invoked to produce a certain package.
$(COMMANDS_DIR)/%.sh: $(PACKAGES_DIR)/%.json
	@{ echo "# Build package: $$(jq -r '.PACKAGE_NAME' < $<)"; } > $@ 
	@{ jq 'to_entries | .[] | "\(.key)=\(.value)"' < $<; echo "make build"; } | xargs >> $@

# LIST just plonks all the package json files generated above into an array,
# and converts it to YAML.
$(LIST): $(PACKAGES)
	@jq -s '{ packages: . }' $$(find $(PACKAGES)) | yq -y . >$@

$(LOCK): $(LIST)
	@echo "### ***" > $@
	@echo "### WARNING: DO NOT manually EDIT or MERGE this file, it is generated by 'make $@'." >> $@
	@echo "### INSTEAD: Edit or merge the source in this directory then run 'make $@'." >> $@
	@echo "### ***" >> $@
	@cat $< >> $@
