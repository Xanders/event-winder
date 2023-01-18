# Show this help
help:
	@cat $(MAKEFILE_LIST) | docker run --rm -i xanders/make-help

# Test the library
test:
	docker-compose run --rm -e EVENT_WINDER_RUNTIME_ERRORS=true crystal spec

# Check the code style is correct
lint:
	docker-compose run --rm crystal tool format --check

# Change source files according to code style
lint!:
	docker-compose run --rm crystal tool format

# Generate the documentation
docs:
	docker-compose run --rm crystal docs

.PHONY: docs
