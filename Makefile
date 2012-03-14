
all: lib/stitch.js

lib/stitch.js: src/stitch.coffee
	./node_modules/.bin/coffee -c -o lib/ src/

.PHONY: test
test:
	./node_modules/.bin/nodeunit test/

publish: lib/stitch.js
	npm publish

install: lib/stitch.js
	npm install
