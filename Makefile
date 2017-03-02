# This Makefile builds Felix and packages it in various forms:
#
#                                                                      Go install
#                                                                         Glide
#                                                                           |
#                                                                           |
#                                                                           |
#                                                    +-------+              v
#                                                    | Felix |   +---------------------+
#                                                    |  Go   |   | calico/go-build     |
#                                                    |  code |   +---------------------+
#                                                    +-------+         /
#                                                           \         /
#                                                            \       /
#                                                             \     /
#                                                             go build
#                                                                 \
#                                                                  \
#                                                                   \
# +----------------------+                                           :
# | calico-build/centos7 |                                           v
# | calico-build/xenial  |                                 +------------------+
# | calico-build/trusty  |                                 | bin/calico-felix |
# +----------------------+                                 +------------------+
#                     \                                          /   /
#                      \             .--------------------------'   /
#                       \           /                              /
#                        \         /                      .-------'
#                         \       /                      /
#                     rpm/build-rpms                    /
#                   debian/build-debs                  /
#                           |                         /
#                           |                   docker build
#                           v                         |
#            +----------------------------+           |
#            |  RPM packages for Centos7  |           |
#            |  RPM packages for Centos6  |           v
#            | Debian packages for Xenial |    +--------------+
#            | Debian packages for Trusty |    | calico/felix |
#            +----------------------------+    +--------------+
#
#

help:
	@echo "Felix Makefile"
	@echo
	@echo "Dependencies: docker 1.12+; go 1.7+"
	@echo
	@echo "Note: initial builds can be slow because they generate docker-based"
	@echo "build environments."
	@echo
	@echo "Initial set-up:"
	@echo
	@echo "  make update-tools  Update/install the go build dependencies."
	@echo
	@echo "Builds:"
	@echo
	@echo "  make all           Build all the binary packages."
	@echo "  make deb           Build debs in ./dist."
	@echo "  make rpm           Build rpms in ./dist."
	@echo "  make calico/felix  Build calico/felix docker image."
	@echo
	@echo "Tests:"
	@echo
	@echo "  make ut                Run UTs."
	@echo "  make go-cover-browser  Display go code coverage in browser."
	@echo
	@echo "Maintenance:"
	@echo
	@echo "  make update-vendor  Update the vendor directory with new "
	@echo "                      versions of upstream packages.  Record results"
	@echo "                      in glide.lock."
	@echo "  make go-fmt        Format our go code."
	@echo "  make clean         Remove binary files."

# Disable make's implicit rules, which are not useful for golang, and slow down the build
# considerably.
.SUFFIXES:

all: deb rpm calico/felix
test: ut

GO_BUILD_CONTAINER?=calico/go-build:v0.4

# Figure out version information.  To support builds from release tarballs, we default to
# <unknown> if this isn't a git checkout.
GIT_COMMIT:=$(shell git rev-parse HEAD || echo '<unknown>')
BUILD_ID:=$(shell git rev-parse HEAD || uuidgen | sed 's/-//g')
GIT_DESCRIPTION:=$(shell git describe --tags || echo '<unknown>')

# Calculate a timestamp for any build artefacts.
DATE:=$(shell date -u +'%FT%T%z')

# List of Go files that are generated by the build process.  Builds should
# depend on these, clean removes them.
GENERATED_GO_FILES:=proto/felixbackend.pb.go

# Directories that aren't part of the main Felix program,
# e.g. standalone test programs.
K8SFV_DIR:=k8sfv
NON_FELIX_DIRS:=$(K8SFV_DIR)

# All Felix go files.
FELIX_GO_FILES:=$(shell find . $(foreach dir,$(NON_FELIX_DIRS),-path ./$(dir) -prune -o) -type f -name '*.go' -print) $(GENERATED_GO_FILES)

# Files for the Felix+k8s backend test program.
K8SFV_GO_FILES:=$(shell find ./$(K8SFV_DIR) -name prometheus -prune -o -type f -name '*.go' -print)

# Figure out the users UID/GID.  These are needed to run docker containers
# as the current user and ensure that files built inside containers are
# owned by the current user.
MY_UID:=$(shell id -u)
MY_GID:=$(shell id -g)

# Build a docker image used for building debs for trusty.
.PHONY: calico-build/trusty
calico-build/trusty:
	cd docker-build-images && docker build -f ubuntu-trusty-build.Dockerfile -t calico-build/trusty .

# Build a docker image used for building debs for xenial.
.PHONY: calico-build/xenial
calico-build/xenial:
	cd docker-build-images && docker build -f ubuntu-xenial-build.Dockerfile -t calico-build/xenial .

# Construct a docker image for building Centos 7 RPMs.
.PHONY: calico-build/centos7
calico-build/centos7:
	cd docker-build-images && \
	  docker build \
	  --build-arg=UID=$(MY_UID) \
	  --build-arg=GID=$(MY_GID) \
	  -f centos7-build.Dockerfile \
	  -t calico-build/centos7 .

# Construct a docker image for building Centos 6 RPMs.
.PHONY: calico-build/centos6
calico-build/centos6:
	cd docker-build-images && \
	  docker build \
	  --build-arg=UID=$(MY_UID) \
	  --build-arg=GID=$(MY_GID) \
	  -f centos6-build.Dockerfile \
	  -t calico-build/centos6 .

# Build the calico/felix docker image, which contains only Felix.
.PHONY: calico/felix
calico/felix: bin/calico-felix
	rm -rf docker-image/bin
	mkdir -p docker-image/bin
	cp bin/calico-felix docker-image/bin/
	docker build -t calico/felix docker-image

# Targets for Felix testing with the k8s backend and a k8s API server,
# with k8s model resources being injected by a separate test client.
LOCAL_IP_ENV?=$(shell ip route get 8.8.8.8 | head -1 | awk '{print $$7}')
K8S_VERSION=1.5.3
FELIX_K8S=felix-k8s
.PHONY: k8s-fv-test run-k8s-apiserver stop-k8s-apiserver run-etcd stop-etcd
k8s-fv-test: calico/felix run-k8s-apiserver k8sfv/k8sfv.test
	@-docker rm -f $(FELIX_K8S)
	sleep 1
	docker run --detach --privileged --name=$(FELIX_K8S) \
	-e FELIX_LOGSEVERITYSCREEN=info \
	-e FELIX_DATASTORETYPE=kubernetes \
	-e FELIX_PROMETHEUSMETRICSENABLED=true \
	-e K8S_API_ENDPOINT=https://$(LOCAL_IP_ENV):6443 \
	-e K8S_INSECURE_SKIP_TLS_VERIFY=true \
	-v $${PWD}:/testcode \
	-p 9091:9091 \
	calico/felix \
	/bin/sh -c "for n in 1 2; do calico-felix; done"
	sleep 1
	docker exec $(FELIX_K8S) /testcode/k8sfv/k8sfv.test -ginkgo.v https://$(LOCAL_IP_ENV):6443

run-k8s-apiserver: stop-k8s-apiserver run-etcd
	docker run --detach --net=host \
	  --name calico-k8s-apiserver \
	gcr.io/google_containers/hyperkube-amd64:v$(K8S_VERSION) \
		  /hyperkube apiserver --etcd-servers=http://$(LOCAL_IP_ENV):2379 \
		  --service-cluster-ip-range=10.101.0.0/16 -v=10

stop-k8s-apiserver: stop-etcd
	@-docker rm -f calico-k8s-apiserver
	sleep 2

run-etcd: stop-etcd
	docker run --detach \
	-p 2379:2379 \
	--name calico-etcd quay.io/coreos/etcd \
	etcd \
	--advertise-client-urls "http://$(LOCAL_IP_ENV):2379,http://127.0.0.1:2379,http://$(LOCAL_IP_ENV):4001,http://127.0.0.1:4001" \
	--listen-client-urls "http://0.0.0.0:2379,http://0.0.0.0:4001"

stop-etcd:
	@-docker rm -f calico-etcd

.PHONY: run-prometheus run-grafana
run-prometheus:
	docker run --detach --rm --name prometheus -p 9090:9090 \
	-v $${PWD}/$(K8SFV_DIR)/prometheus/prometheus.yml:/etc/prometheus.yml \
	-v $${PWD}/$(K8SFV_DIR)/prometheus/data:/prometheus \
	prom/prometheus \
	-config.file=/etc/prometheus.yml \
	-storage.local.path=/prometheus

run-grafana:
	docker run --detach --rm --name grafana --net=host \
	grafana/grafana

# Pre-configured docker run command that runs as this user with the repo
# checked out to /code, uses the --rm flag to avoid leaving the container
# around afterwards.
DOCKER_RUN_RM:=docker run --rm --user $(MY_UID):$(MY_GID) -v $${PWD}:/code
DOCKER_RUN_RM_ROOT:=docker run --rm -v $${PWD}:/code

# Allow libcalico-go and the ssh auth sock to be mapped into the build container.
ifdef LIBCALICOGO_PATH
  EXTRA_DOCKER_ARGS += -v $(LIBCALICOGO_PATH):/go/src/github.com/projectcalico/libcalico-go:ro
endif
ifdef SSH_AUTH_SOCK
  EXTRA_DOCKER_ARGS += -v $(SSH_AUTH_SOCK):/ssh-agent --env SSH_AUTH_SOCK=/ssh-agent
endif
DOCKER_GO_BUILD := mkdir -p .go-pkg-cache && \
                   docker run --rm \
                              --net=host \
                              $(EXTRA_DOCKER_ARGS) \
                              -e LOCAL_USER_ID=$(MY_UID) \
                              -v $${PWD}:/go/src/github.com/projectcalico/felix:rw \
                              -v $${PWD}/.go-pkg-cache:/go/pkg:rw \
                              -w /go/src/github.com/projectcalico/felix \
                              $(GO_BUILD_CONTAINER)

# Build all the debs.
.PHONY: deb
deb: dist/calico-felix/calico-felix
ifeq ($(GIT_COMMIT),<unknown>)
	$(error Package builds must be done from a git working copy in order to calculate version numbers.)
endif
	$(MAKE) calico-build/trusty
	$(MAKE) calico-build/xenial
	utils/make-packages.sh deb

# Build RPMs.
.PHONY: rpm
rpm: dist/calico-felix/calico-felix
ifeq ($(GIT_COMMIT),<unknown>)
	$(error Package builds must be done from a git working copy in order to calculate version numbers.)
endif
	$(MAKE) calico-build/centos7
	$(MAKE) calico-build/centos6
	utils/make-packages.sh rpm

.PHONY: protobuf
protobuf: proto/felixbackend.pb.go

# Generate the protobuf bindings for go.
proto/felixbackend.pb.go: proto/felixbackend.proto
	$(DOCKER_RUN_RM) -v $${PWD}/proto:/src:rw \
	              calico/protoc \
	              --gogofaster_out=. \
	              felixbackend.proto

# Update the vendored dependencies with the latest upstream versions matching
# our glide.yaml.  If there area any changes, this updates glide.lock
# as a side effect.  Unless you're adding/updating a dependency, you probably
# want to use the vendor target to install the versions from glide.lock.
.PHONY: update-vendor
update-vendor:
	mkdir -p $$HOME/.glide
	$(DOCKER_GO_BUILD) glide up --strip-vendor
	touch vendor/.up-to-date

# vendor is a shortcut for force rebuilding the go vendor directory.
.PHONY: vendor
vendor vendor/.up-to-date: glide.lock
	mkdir -p $$HOME/.glide
	$(DOCKER_GO_BUILD) glide install --strip-vendor
	touch vendor/.up-to-date

# Linker flags for building Felix.
#
# We use -X to insert the version information into the placeholder variables
# in the buildinfo package.
#
# We use -B to insert a build ID note into the executable, without which, the
# RPM build tools complain.
LDFLAGS:=-ldflags "\
        -X github.com/projectcalico/felix/buildinfo.GitVersion=$(GIT_DESCRIPTION) \
        -X github.com/projectcalico/felix/buildinfo.BuildDate=$(DATE) \
        -X github.com/projectcalico/felix/buildinfo.GitRevision=$(GIT_COMMIT) \
        -B 0x$(BUILD_ID)"

bin/calico-felix: $(FELIX_GO_FILES) vendor/.up-to-date
	@echo Building felix...
	mkdir -p bin
	$(DOCKER_GO_BUILD) \
	    sh -c 'go build -v -i -o $@ -v $(LDFLAGS) "github.com/projectcalico/felix" && \
               ( ldd bin/calico-felix 2>&1 | grep -q "Not a valid dynamic program" || \
	             ( echo "Error: bin/calico-felix was not statically linked"; false ) )'

k8sfv/k8sfv.test: $(K8SFV_GO_FILES)
	@echo Building $@...
	$(DOCKER_GO_BUILD) \
	    sh -c 'ginkgo build k8sfv && \
               ( ldd $@ 2>&1 | grep -q "Not a valid dynamic program" || \
	             ( echo "Error: $@ was not statically linked"; false ) )'

dist/calico-felix/calico-felix: bin/calico-felix
	mkdir -p dist/calico-felix/
	cp bin/calico-felix dist/calico-felix/calico-felix

# Install or update the tools used by the build
.PHONY: update-tools
update-tools:
	go get -u github.com/Masterminds/glide
	go get -u github.com/onsi/ginkgo/ginkgo

# Run go fmt on all our go files.
.PHONY: go-fmt goimports
go-fmt goimports:
	$(DOCKER_GO_BUILD) sh -c 'glide nv -x | \
	                          grep -v -e "^\\.$$" | \
	                          xargs goimports -w -local github.com/projectcalico/ *.go'

check-licenses/dependency-licenses.txt: vendor/.up-to-date
	$(DOCKER_GO_BUILD) sh -c 'licenses . > check-licenses/dependency-licenses.txt'

.PHONY: ut
ut combined.coverprofile: vendor/.up-to-date $(FELIX_GO_FILES)
	@echo Running Go UTs.
	$(DOCKER_GO_BUILD) ./utils/run-coverage

bin/check-licenses: $(FELIX_GO_FILES)
	$(DOCKER_GO_BUILD) go build -v -i -o $@ "github.com/projectcalico/felix/check-licenses"

.PHONY: check-licenses
check-licenses: check-licenses/dependency-licenses.txt bin/check-licenses
	@echo Checking dependency licenses
	$(DOCKER_GO_BUILD) bin/check-licenses

.PHONY: go-meta-linter
go-meta-linter: vendor/.up-to-date
	$(DOCKER_GO_BUILD) gometalinter --deadline=300s \
	                                --disable-all \
	                                --enable=goimports \
	                                --enable=staticcheck \
	                                --vendor ./...

.PHONY: static-checks
static-checks:
	$(MAKE) go-meta-linter check-licenses

.PHONY: ut-no-cover
ut-no-cover: vendor/.up-to-date $(FELIX_GO_FILES)
	@echo Running Go UTs without coverage.
	$(DOCKER_GO_BUILD) ginkgo -r

.PHONY: ut-watch
ut-watch: vendor/.up-to-date $(FELIX_GO_FILES)
	@echo Watching go UTs for changes...
	$(DOCKER_GO_BUILD) ginkgo watch -r

# Launch a browser with Go coverage stats for the whole project.
.PHONY: cover-browser
cover-browser: combined.coverprofile
	go tool cover -html="combined.coverprofile"

.PHONY: cover-report
cover-report: combined.coverprofile
	# Print the coverage.  We use sed to remove the verbose prefix and trim down
	# the whitespace.
	@echo
	@echo ======== All coverage =========
	@echo
	@$(DOCKER_GO_BUILD) sh -c 'go tool cover -func combined.coverprofile | \
	                           sed 's=github.com/projectcalico/felix/==' | \
	                           column -t'
	@echo
	@echo ======== Missing coverage only =========
	@echo
	@$(DOCKER_GO_BUILD) sh -c "go tool cover -func combined.coverprofile | \
	                           sed 's=github.com/projectcalico/felix/==' | \
	                           column -t | \
	                           grep -v '100\.0%'"

.PHONY: upload-to-coveralls
upload-to-coveralls: combined.coverprofile
ifndef COVERALLS_REPO_TOKEN
	$(error COVERALLS_REPO_TOKEN is undefined - run using make upload-to-coveralls COVERALLS_REPO_TOKEN=abcd)
endif
	$(DOCKER_GO_BUILD) goveralls -repotoken=$(COVERALLS_REPO_TOKEN) -coverprofile=combined.coverprofile

bin/calico-felix.transfer-url: bin/calico-felix
	$(DOCKER_GO_BUILD) sh -c 'curl --upload-file bin/calico-felix https://transfer.sh/calico-felix > $@'

.PHONY: patch-script
patch-script: bin/calico-felix.transfer-url
	$(DOCKER_GO_BUILD) bash -c 'utils/make-patch-script.sh $$(cat bin/calico-felix.transfer-url)'

# Generate a diagram of Felix's internal calculation graph.
docs/calc.pdf: docs/calc.dot
	cd docs/ && dot -Tpdf calc.dot -o calc.pdf

.PHONY: clean
clean:
	rm -rf bin \
	       docker-image/bin \
	       dist \
	       build \
	       $(GENERATED_GO_FILES) \
	       go/docs/calc.pdf \
	       .glide \
	       vendor \
	       .go-pkg-cache \
	       check-licenses/dependency-licenses.txt \
	       release-notes-*
	find . -name "*.coverprofile" -type f -delete
	find . -name "coverage.xml" -type f -delete
	find . -name ".coverage" -type f -delete
	find . -name "*.pyc" -type f -delete

.PHONY: release release-once-tagged
release: clean
ifndef VERSION
	$(error VERSION is undefined - run using make release VERSION=X.Y.Z)
endif
ifeq ($(GIT_COMMIT),<unknown>)
	$(error git commit ID couldn't be determined, releases must be done from a git working copy)
endif
	$(DOCKER_GO_BUILD) utils/tag-release.sh $(VERSION)

.PHONY: continue-release
continue-release:
	@echo "Edited release notes are:"
	@echo
	@cat ./release-notes-$(VERSION)
	@echo
	@echo "Hit Return to go ahead and create the tag, or Ctrl-C to cancel."
	@bash -c read
	# Create annotated release tag.
	git tag $(VERSION) -F ./release-notes-$(VERSION)
	rm ./release-notes-$(VERSION)

	# Now decouple onto another make invocation, as we want some variables
	# (GIT_DESCRIPTION and BUNDLE_FILENAME) to be recalculated based on the
	# new tag.
	$(MAKE) release-once-tagged

release-once-tagged:
	@echo
	@echo "Will now build release artifacts..."
	@echo
	$(MAKE) bin/calico-felix calico/felix
	docker tag calico/felix calico/felix:$(VERSION)
	docker tag calico/felix:$(VERSION) quay.io/calico/felix:$(VERSION)
	@echo
	@echo "Checking built felix has correct version..."
	@if docker run quay.io/calico/felix:$(VERSION) calico-felix --version | grep -q '$(VERSION)$$'; \
	then \
	  echo "Check successful."; \
	else \
	  echo "Incorrect version in docker image!"; \
	  false; \
	fi
	@echo
	@echo "Felix release artifacts have been built:"
	@echo
	@echo "- Binary:                 bin/calico-felix"
	@echo "- Docker container image: calico/felix:$(VERSION)"
	@echo "- Same, tagged for Quay:  quay.io/calico/felix:$(VERSION)"
	@echo
	@echo "Now to publish this release to Github:"
	@echo
	@echo "- Push the new tag ($(VERSION)) to https://github.com/projectcalico/felix"
	@echo "- Go to https://github.com/projectcalico/felix/releases/tag/$(VERSION)"
	@echo "- Copy the tag content (release notes) shown on that page"
	@echo "- Go to https://github.com/projectcalico/felix/releases/new?tag=$(VERSION)"
	@echo "- Paste the copied tag content into the large textbox"
	@echo "- Attach the binary"
	@echo "- Click the 'This is a pre-release' checkbox, if appropriate"
	@echo "- Click 'Publish release'"
	@echo
	@echo "Then, push the docker images to Dockerhub and Quay:"
	@echo
	@echo "- docker push calico/felix:$(VERSION)"
	@echo "- docker push quay.io/calico/felix:$(VERSION)"
	@echo
	@echo "If you also want to build Debian/Ubuntu and RPM packages for"
	@echo "the new release, use 'make deb' and 'make rpm'."
	@echo
