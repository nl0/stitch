{ parse } = require 'url'


# This middleware will automatically compile packages when they are requested.
# There is considerable overhead when compiling a package, so this middleware
# is not suitable for a production environment. There you should precompile
# the packages before you deploy the code to the server.
#
# The `packages` argument is an object whose keys are URL paths, and the
# values are the respective packages. Example:
#
#  stitch.middleware({ '/assets/app.js': stitch.createPackage(...) })

module.exports = (packages) ->

  return (req, res, next) ->
    # Only respond to GET or HEAD requests.
    return next() unless req.method is 'GET' or req.method is 'HEAD'

    # Pass on to the next handler if a package definition for this path
    # doesn't exist. If we're lucky some other handler will know what to do
    # (static provider for example), otherwise the server returns 404.
    path = parse(req.url).pathname
    return next() unless package = packages[path]

    # Alright, compile the package and send it to the client.
    package.compile (err, source) ->
      return next err if err

      res.contentType 'js'
      res.send source
