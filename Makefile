VERSION=$(shell python setup.py --version)
DOCKER_RUN = docker run -t -v $(CURDIR):/work:rw -v $(CURDIR)/.tox-indocker:/work/.tox:rw
UID:=$(shell id -u)
GID:=$(shell id -g)

ifeq ($(findstring .yelpcorp.com,$(shell hostname -f)), .yelpcorp.com)
	PAASTA_ENV ?= YELP
else
	PAASTA_ENV ?= $(shell hostname --fqdn)
endif

NOOP = true
ifeq ($(PAASTA_ENV),YELP)
	export PIP_INDEX_URL ?= https://pypi.yelpcorp.com/simple
	export NPM_CONFIG_REGISTRY ?= https://npm.yelpcorp.com/
	ADD_MISSING_DEPS_MAYBE:=-diff --unchanged-line-format= --old-line-format= --new-line-format='%L' ./requirements.txt ./yelp_package/extra_requirements_yelp.txt >> ./requirements.txt
else
	export PIP_INDEX_URL ?= https://pypi.python.org/simple
	export NPM_CONFIG_REGISTRY ?= https://registry.npmjs.org
	ADD_MISSING_DEPS_MAYBE:=$(NOOP)
endif

.PHONY : all clean tests docs dev cluster_itests

-usage:
	@echo "make test - Run tests"
	@echo "make deb_bionic - Generate bionic deb package"
	@echo "make itest_bionic - Run tests and integration checks"
	@echo "make _itest_bionic - Run only integration checks"
	@echo "make release - Prepare debian info for new release"
	@echo "make clean - Get rid of scratch and byte files"
	@echo "make dev - Get a local copy of trond running in debug mode in the foreground"

docker_%:
	@echo "Building docker image for $*"
	[ -d dist ] || mkdir -p dist
	cd ./yelp_package/$* && docker build --build-arg PIP_INDEX_URL=${PIP_INDEX_URL} --build-arg NPM_CONFIG_REGISTRY=${NPM_CONFIG_REGISTRY} -t tron-builder-$* .

deb_%: clean docker_% coffee_% react_%
	@echo "Building deb for $*"
	# backup these files so we can temp modify them
	cp requirements.txt requirements.txt.old
	$(ADD_MISSING_DEPS_MAYBE)
	$(DOCKER_RUN) -e PIP_INDEX_URL=${PIP_INDEX_URL} tron-builder-$* /bin/bash -c ' \
		dpkg-buildpackage -d &&                  \
		mv ../*.deb dist/ &&                     \
		rm -rf debian/tron &&                    \
		chown -R $(UID):$(GID) dist debian       \
	'
	# restore the backed up files
	mv requirements.txt.old requirements.txt

coffee_%: docker_%
	@echo "Building tronweb"
	$(DOCKER_RUN) tron-builder-$* /bin/bash -c '       \
		rm -rf tronweb/js/cs &&                        \
		mkdir -p tronweb/js/cs &&                      \
		coffee -o tronweb/js/cs/ -c tronweb/coffee/ && \
		chown -R $(UID):$(GID) tronweb/js/cs/          \
	'

react_%: docker_%
	@echo "Building tronweb2"
	$(DOCKER_RUN) tron-builder-$* /bin/bash -c '       \
		YARN_REGISTRY=${NPM_CONFIG_REGISTRY} yarn --cwd tronweb2 &&                         \
		YARN_REGISTRY=${NPM_CONFIG_REGISTRY} yarn --cwd tronweb2 build &&                   \
		chown -R $(UID):$(GID) tronweb2/build/ tronweb2/node_modules         \
	'

test:
	tox -e py36

test_in_docker_%: docker_%
	$(DOCKER_RUN) tron-builder-$* python3.6 -m tox -vv -e py36

tox_%:
	tox -e $*

_itest_%:
	$(DOCKER_RUN) -e NPM_CONFIG_REGISTRY=${NPM_CONFIG_REGISTRY} ubuntu:$* /work/itest.sh

debitest_%: deb_% _itest_%
	@echo "Package for $* looks good"

itest_%: debitest_%
	@echo "itest $* OK"

cluster_itests:
	tox -e cluster_itests

dev:
	SSH_AUTH_SOCK=$(SSH_AUTH_SOCK) .tox/py36/bin/trond --debug --working-dir=dev -l logging.conf --host=0.0.0.0

example_cluster:
	tox -e example-cluster

yelpy:
	.tox/py36/bin/pip-custom-platform install -i https://pypi.yelpcorp.com/simple -r yelp_package/extra_requirements_yelp.txt

LAST_COMMIT_MSG = $(shell git log -1 --pretty=%B | sed -e 's/[\x27\x22]/\\\x27/g')
release: docker_bionic docs
	$(DOCKER_RUN) tron-builder-bionic /bin/bash -c " \
		dch -v $(VERSION) --distribution bionic --changelog debian/changelog \
			$$'$(VERSION) tagged with \'make release\'\rCommit: $(LAST_COMMIT_MSG)' && \
		chown $(UID):$(GID) debian/changelog \
	"
	@git diff
	@echo "Now Run:"
	@echo 'git commit -a -m "Released $(VERSION) via make release"'
	@echo 'git tag --force v$(VERSION)'
	@echo 'git push --tags origin master'

docs:
	tox -r -e docs

man:
	which $(SPHINXBUILD) >/dev/null && $(SPHINXBUILD) -b man $(ALLSPHINXOPTS) $(DOCS_DIR) $(DOCS_DIR)/man || true
	@echo
	@echo "Build finished. The manual pages are in $(DOCS_BUILDDIR)/man."

clean:
	rm -rf tronweb/js/cs
	find . -name '*.pyc' -delete
