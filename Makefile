
all: compile

compile: src/stitch.coffee src/middleware.coffee
	./node_modules/.bin/coffee -c -o lib/ src/

.PHONY: test
test:
	./node_modules/.bin/nodeunit test/

publish: compile
	npm publish

install: compile
	npm install
