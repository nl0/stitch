{ readFileSync, readFile, stat, statSync, realpath, readdir } = require 'fs'
{ parallel, map, forEach } = require 'async'
{ extname, join } = require 'path'



# Node does not export what the correct path separator is for the current
# platform. Another way to get it is join("x","x")[1].
SEPARATOR = if process.platform is 'win32' then '\\' else '/'



# A simple implementation of extend. Copied from underscorejs and ported to
# coffee-script.
extend = (obj, args...) ->
  args.forEach (x) -> obj[k] = v for k,v of x
  return obj



# Return a function which wraps the content in a custom compiler. The compiler
# is given the raw file contents (in utf8) and is expected to return the
# compiled source.
customCompiler = (fn) -> (module, filename) ->
    content = fn readFileSync filename, 'utf8'
    module._compile content, filename



# The list of all compilers that we support. Out of the box only pure
# javascript is supported. But if coffee-script or eco are installed we know
# how to compile those as well.
exports.compilers = compilers =
  js: customCompiler (x) -> x


try
  CoffeeScript = require 'coffee-script'
  compilers.coffee = customCompiler CoffeeScript.compile
catch err

try
  eco = require 'eco'
  if eco.precompile
    compilers.eco = customCompiler (x) -> "module.exports = #{eco.precompile x}"
  else
    compilers.eco = customCompiler eco.compile
catch err



# A package is a collection of files which are compiled into one single big
# string.
exports.Package = class Package
  constructor: (config) ->
    @identifier   = config.identifier ? 'require'
    @paths        = config.paths ? ['lib']
    @dependencies = config.dependencies ? []
    @compilers    = extend {}, compilers, config.compilers

    @cache        = config.cache ? true
    @mtimeCache   = {}
    @compileCache = {}


  # Compile the package and invoke the callback with the result. The callback
  # will be given two arguments, (err, source). Source is the compiled package
  # as a string.
  compile: (callback) ->
    done = (err, x) -> if err then callback(err) else callback null, x.join "\n"
    parallel [ @compileDependencies, @compileSources ], done


  # Dependencies are treated as plaintext files and are not compiled. They are
  # simply prepended to the result. Note that no particular ordering is
  # guaranteed for those files!
  compileDependencies: (callback) =>
    map @dependencies, readFile, (err, deps) ->
      if err then callback(err) else callback null, deps.join "\n"


  # Compile all sources into a stringified object, where the key is the module
  # name and value the module loader function. Useful if you want to wrap the
  # module in a different header/footer (such as to support AMD).
  compiledSourceDefinitions: (callback) ->
    # Object holding all modules. We use the module relative path as the key,
    # to detect duplicate keys.
    sources = {}


    # Insert a compiled source into our `sources` object while checking for
    # duplicate keys.
    addCompiledSource = (key, source, next) ->
      if sources[key]
        next new Error "#{key} exists more than once in the package"
      else
        sources[key] = source
        next null


    # Compile a single source file and add it to the `sources` object. No two
    # packages with the same relative path may exist, because one would shadow
    # the other. If that happens fail with an error.
    compileSourceFile = (path, next) =>
      # Skip files which we don't know how to compile.
      return next null unless @compilers[extname(path).slice(1)]

      @getRelativePath path, (err, relativePath) =>
        return next err if err

        @compileFile path, (err, source) ->
          return next err if err

          key = relativePath.slice 0, -extname(relativePath).length
          addCompiledSource key, source, next


    # The iterator is called once for each path in @paths. If the path points
    # to a file, then that file is compiled, otherwise all files underneath
    # that path are collected and compiled.
    iterator = (path, next) =>
      stat path, (err, stat) =>
        return next err if err

        if stat.isDirectory()
          @getFilesInTree path, (err, paths) =>
            return next err if err
            forEach paths, compileSourceFile, next
        else
          compileSourceFile path, next


    forEach @paths, iterator, (err) =>
      return callback err if err

      modules = for name, source of sources
        func = ": function(exports, require, module) {#{source}\n}"
        [ JSON.stringify(name), func ].join ""

      callback null, "{#{modules.join ","}}"


  # Compile all files under @paths, and merge them into one single big file.
  compileSources: (callback) =>
    @compiledSourceDefinitions (err, definitions) =>
      callback err if err

      result = """
        (function(/*! Stitch !*/) {
          if (!this.#{@identifier}) {
            var modules = {}, cache = {}, require = function(name, root) {
              var fn, module, path = expand(root, name),
                altPath = expand(path, './index');

              if (module = cache[path] || cache[altPath]) {
                return module.exports;
              } else if (fn = modules[path] || modules[path = altPath]) {
                module = {id: path, exports: {}};
                try {
                  cache[path] = module;
                  fn(module.exports, function(name) {
                    return require(name, dirname(path));
                  }, module);
                  return module.exports;
                } catch (err) {
                  delete cache[path];
                  throw err;
                }
              } else {
                throw 'module \\'' + name + '\\' not found';
              }
            }, expand = function(root, name) {
              var results = [], parts, part;
              if (/^\\.\\.?(\\/|$)/.test(name)) {
                parts = [root, name].join('/').split('/');
              } else {
                parts = name.split('/');
              }
              for (var i = 0, length = parts.length; i < length; i++) {
                part = parts[i];
                if (part == '..') {
                  results.pop();
                } else if (part != '.' && part != '') {
                  results.push(part);
                }
              }
              return results.join('/');
            }, dirname = function(path) {
              return path.split('/').slice(0, -1).join('/');
            };
            this.#{@identifier} = function(name) {
              return require(name, '');
            }
            this.#{@identifier}.define = function(bundle) {
              for (var key in bundle)
                modules[key] = bundle[key];
            };
          }
          return this.#{@identifier}.define;
        }).call(this)(#{definitions});\n
      """

      callback err, result

  createServer: ->
    (req, res, next) =>
      @compile (err, source) ->
        if err
          console.error "#{err.stack}"
          message = "" + err.stack
          res.writeHead 500, 'Content-Type': 'text/javascript'
          res.end "throw #{JSON.stringify(message)}"
        else
          res.writeHead 200, 'Content-Type': 'text/javascript'
          res.end source


  # Return the relative path of `path` to any of the base paths that make up
  # this package. The relative path will be the path that the modules inside
  # the package can use to require() this file. The relative path is
  # normalized to only contain forward slashes, even on windows.
  getRelativePath: (path, callback) ->
    realpath path, (err, sourcePath) =>
      return callback err if err

      map @paths, realpath, (err, expandedPaths) ->
        return callback err if err

        for expandedPath in expandedPaths
          # If the path is a directory, append the path separator to it. This
          # is to avoid matching a directory with a file with the same name.
          base = expandedPath
          if statSync(expandedPath).isDirectory()
            base += SEPARATOR

          # If `base` is a prefix of the `sourcePath`, then we found our file.
          # Strip the base from the source path and we get the relative path.
          # Also replace all backslashes with forward slashes, to make the
          # path consistent across unix and windows.
          if sourcePath.indexOf(base) is 0
            relativePath = sourcePath.slice(base.length).replace /\\/g, "/"
            return callback null, relativePath

        callback new Error "#{path} isn't in the require path"


  # Compile the file at `path` and invoke the callback with (err, source),
  # where `source` is the compiled source as string. If enabled through the
  # options, the compiled source is cached.
  compileFile: (path, callback) ->
    extension = extname(path).slice(1)

    if @cache and @compileCache[path] and @mtimeCache[path] is @compileCache[path].mtime
      callback null, @compileCache[path].source
    else if compile = @compilers[extension]
      source = null
      mod =
        _compile: (content, filename) ->
          source = content

      try
        compile mod, path

        if @cache and mtime = @mtimeCache[path]
          @compileCache[path] = {mtime, source}

        callback null, source
      catch err
        if err instanceof Error
          err.message = "can't compile #{path}\n#{err.message}"
        else
          err = new Error "can't compile #{path}\n#{err}"
        callback err
    else
      callback new Error "no compiler for '.#{extension}' files"



  # Tree walking
  # ------------
  #
  # This section is about recursively walking a particular filesystem tree and
  # gathering all files underneath.

  # Walk the directory and collect all files. Invoke the callback with
  # (err, files). The files array is sorted.
  getFilesInTree: (directory, cb) ->
    files = []

    iterator  = (file) -> files.push file
    finalizer = (err)  -> if err then cb(err) else cb null, files.sort()

    @walkTree directory, iterator, finalizer


  # Recursively walk the directory, invoking the iterator once for each file
  # that is found. If at any point an error is encountered, the finalizer is
  # called with the error in its first argument. If the tree walk completed
  # without errors the finalizer is called with no arguments.
  walkTree: (directory, iterator, finalizer) ->
    readdir directory, (err, files) =>
      return finalizer err if err

      # The function that is called for each dirent. The first argument is the
      # dirent, the second a callback that has to be invoked when the function
      # is finished with its asynchronous operations.
      iter = (file, next) =>
        return next() if file.match /^\./

        filename = join directory, file
        stat filename, (err, stats) =>
          return next err if err

          @mtimeCache[filename] = stats.mtime.toString()

          if stats.isDirectory()
            @walkTree filename, iterator, next
          else
            iterator filename
            next()

      forEach files, iter, finalizer



exports.createPackage = (config) ->
  new Package config
